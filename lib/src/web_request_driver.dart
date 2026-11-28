import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_outcome_vocabulary/is_outcome_vocabulary.dart';
import 'package:is_web_request_vocabulary/is_web_request_vocabulary.dart';
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart';
import 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart';
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart';

import 'credential.dart';

/// One HTTP response: its [status], its [body] or null when the body ran
/// past the call's limit, and the address a redirect names in [location].
typedef HttpResult = ({int status, Uint8List? body, Uri? location});

/// Makes one HTTP call, reading at most [maxBytes] of the body and never
/// following a redirect. Injected, so the driver is testable without a
/// network.
typedef HttpCall = Future<HttpResult> Function(
  String method,
  Uri url,
  Map<String, String> headers,
  String body,
  int maxBytes,
);

/// The web request driver: a service on a Unix socket that only the
/// airlock's user may call. It runs as its own user, so a sign-in's secret
/// is readable by this process and no other: not the airlock, not another
/// driver.
///
/// A caller connects, writes one [GrantedRequest] as JSON
/// ([encodeGrantedRequest]) and closes its side; the driver answers one line, the
/// `Outcome<WebResponse>` ([encodeOutcome]), and closes. Who is calling is
/// read from the socket as the kernel reports it, never from the request.
///
/// Each request is signed with the secret of the sign-in it names, and sent
/// only to the sites that sign-in is for.
final class WebRequestDriver {
  WebRequestDriver._(
    Map<SignIn, Credential> signIns,
    this.maxBodyBytes,
    this._http,
    this._now,
    this._log,
    this._socketUserCheck,
    this._socket,
    this._server,
  ) : _signIns = Map.unmodifiable(signIns);

  /// Listens on [socket], carrying out requests under [signIns] for the
  /// user [caller] alone. A socket file nothing listens on is replaced.
  /// [http], [now], [log] and [socketUserReader] are `dart:io`'s, the
  /// clock's, silence and the running kernel's by default.
  static Future<WebRequestDriver> start(
    Map<SignIn, Credential> signIns, {
    required UserId caller,
    required File socket,
    HttpCall? http,
    DateTime Function()? now,
    void Function(String line)? log,
    SocketUserReader? socketUserReader,
    int maxBodyBytes = defaultMaxBodyBytes,
  }) async {
    final driver = WebRequestDriver._(
      signIns,
      maxBodyBytes,
      http ?? httpCall,
      now ?? DateTime.now,
      log ?? _silent,
      SocketUserCheck.only(caller, reader: socketUserReader),
      socket,
      await _bind(socket),
    );
    driver._server.listen(driver._serve);
    return driver;
  }

  final Map<SignIn, Credential> _signIns;
  final HttpCall _http;
  final DateTime Function() _now;
  final SocketUserCheck _socketUserCheck;
  final File _socket;
  final ServerSocket _server;

  /// The largest body read from a site. A body kept for the logbook that is
  /// larger is [StoppedPartway].
  final int maxBodyBytes;

  static const defaultMaxBodyBytes = 16 * 1024 * 1024;

  /// A request is a web request's headers and body, so far smaller than this.
  static const maxRequest = 1 << 20;

  /// Redirects followed for one request; one more is [StoppedPartway].
  static const maxRedirects = 3;

  /// A token reply is a few hundred bytes; anything near this is not one.
  static const _maxTokenBytes = 64 * 1024;

  /// For whoever runs the driver, not the logbook: one line per 2xx (site,
  /// status, created id), and a refusal's reason when only its body says
  /// it, from a non-2xx reply or a token the sign-in service would not issue.
  final void Function(String line) _log;

  static void _silent(String _) {}

  /// Enough of a body to say why; an error page can run to megabytes.
  static String _clip(String body) =>
      body.length <= 2000 ? body : '${body.substring(0, 2000)}…';

  /// Shared by concurrent web requests, so a burst asks for one token, not many.
  final _tokens = <SignIn, Future<_Token>>{};

  static Future<ServerSocket> _bind(File socket) async {
    final address = InternetAddress(
      socket.path,
      type: InternetAddressType.unix,
    );
    if (socket.existsSync()) {
      try {
        (await Socket.connect(address, 0)).destroy();
        throw StateError('a service is already listening on ${socket.path}');
      } on SocketException {
        socket.deleteSync();
      }
    }
    return ServerSocket.bind(address, 0);
  }

  Future<void> close() async {
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
  }

  Future<void> _serve(Socket socket) async {
    try {
      final verdict = _socketUserCheck.decide(socket);
      if (verdict is! Allowed) {
        _log('refused a caller: $verdict');
        socket.destroy();
        return;
      }
      final request = BytesBuilder(copy: false);
      var tooLarge = false;
      await for (final chunk in socket) {
        if (request.length + chunk.length > maxRequest) {
          tooLarge = true;
          break;
        }
        request.add(chunk);
      }
      final Outcome<WebResponse> outcome;
      if (tooLarge) {
        outcome = const NothingRan('request too large');
      } else {
        final GrantedRequest decoded;
        try {
          decoded = decodeGrantedRequest(
            jsonDecode(utf8.decode(request.takeBytes(), allowMalformed: true)),
          );
        } on FormatException catch (e) {
          await _answer(socket, NothingRan('not a request: ${e.message}'));
          return;
        }
        outcome = await _carryOut(decoded);
      }
      await _answer(socket, outcome);
    } on SocketException {
      socket.destroy();
    }
  }

  static Future<void> _answer(
    Socket socket,
    Outcome<WebResponse> outcome,
  ) async {
    try {
      socket.add(
        utf8.encode(
          '${jsonEncode(encodeOutcome(outcome, encodeWebResponse))}\n',
        ),
      );
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  Future<Outcome<WebResponse>> _carryOut(GrantedRequest granted) async {
    final request = granted.proposed;
    final url = _url(request);
    if (url == null) return NothingRan('path leaves ${request.origin}');

    final signIn = request.signIn;
    final credential = signIn == null ? null : _signIns[signIn];
    if (signIn != null && credential == null) {
      return NothingRan('no sign-in $signIn');
    }
    // The airlock decides who may go where by name alone; only here is it
    // known that a secret would ride along to a site that never issued it.
    if (credential != null && !credential.origins.contains(request.origin)) {
      return NothingRan('$signIn is not for ${request.origin}');
    }
    if (credential != null &&
        !credential.reaches(request.origin, request.path)) {
      return NothingRan(
        '$signIn reaches only ${_pins(credential, request.origin)} '
        'on ${request.origin}',
      );
    }

    final signedHeaders = {...request.headers};
    if (credential != null) {
      try {
        signedHeaders['authorization'] = await _authorization(
          signIn!,
          credential,
        );
      } on _TokenRefused catch (e) {
        return NothingRan('$signIn: $e');
      }
    }

    // A redirect is followed only for a GET, which changes nothing, so
    // refusing a hop never hides something the site already did; and only
    // to a site the sign-in is for, or with no sign-in, the site decided on.
    final mayReach = credential?.origins ?? {request.origin};
    final method = request.method.name.toUpperCase();
    final redirects = <RedirectedTo>[];
    var at = url;
    // From here on the request has gone out, so a stop is partway: the
    // last answer that arrived is what was done, and none is not knowing.
    WebResponse? answered;
    HttpResult r;
    while (true) {
      final home = _origin(at) == request.origin;
      try {
        r = await _http(
          method,
          at,
          home ? signedHeaders : request.headers,
          home ? request.body ?? '' : '',
          maxBodyBytes,
        );
      } on IOException catch (e) {
        _log('$method ${redirects.lastOrNull ?? url}: ${_failure(e)}');
        return StoppedPartway(
          why: '${_origin(at)}: ${_failure(e)}',
          done: answered,
        );
      } on TimeoutException {
        return StoppedPartway(why: '${_origin(at)}: timed out', done: answered);
      }
      final location = r.location;
      if (request.method != Method.get ||
          !_redirects.contains(r.status) ||
          location == null) {
        break;
      }
      answered = WebResponse(
        status: r.status,
        redirects: List.unmodifiable(redirects),
      );
      final next = at.resolveUri(location);
      final hop = RedirectedTo.of(next);
      final origin = _origin(next);
      if (hop == null || origin == null || !mayReach.contains(origin)) {
        return StoppedPartway(
          why:
              '${request.origin} redirected to '
              '${origin ?? 'a non-web address'}'
              '${signIn == null ? '' : ', which $signIn is not for'}',
          done: answered,
        );
      }
      // A hop's path is checked without its query, which `covers` ignores
      // and may hold a token. A bare site parses as its root.
      final path = WebPath.parse(next.path);
      // On its own site a hop stays under the grant.
      final grantedPrefix = granted.grantedPathPrefix;
      if (origin == request.origin &&
          (path == null || !grantedPrefix.covers(path))) {
        return StoppedPartway(
          why: '${request.origin} redirected out of $grantedPrefix',
          done: answered,
        );
      }
      // On any pinned site a hop stays where the sign-in reaches.
      if (credential != null &&
          credential.pathPrefixes.containsKey(origin) &&
          (path == null || !credential.reaches(origin, path))) {
        return StoppedPartway(
          why:
              '${request.origin} redirected out of '
              '${_pins(credential, origin)} on $origin',
          done: answered,
        );
      }
      if (redirects.length == maxRedirects) {
        return StoppedPartway(
          why: '${request.origin} redirected more than $maxRedirects times',
          done: answered,
        );
      }
      redirects.add(hop);
      at = next;
    }

    final ok = r.status >= 200 && r.status <= 299;
    final bytes = r.body;
    final text = bytes == null
        ? null
        : utf8.decode(bytes, allowMalformed: true);
    if (!ok) {
      _log(
        '$method $url ${signIn == null ? '' : 'as $signIn '}'
        '${redirects.isEmpty ? '' : 'via ${redirects.join(' ')} '}'
        '${r.status}: ${text == null ? 'body over $maxBodyBytes bytes' : _clip(text)}',
      );
    }
    final created = ok && text != null ? credential?.created?.read(text) : null;
    if (ok) {
      // Site and created id only: a path holds conversation ids, a body
      // whatever the site sent.
      _log(
        '$method ${request.origin} ${signIn == null ? '' : 'as $signIn '}'
        '${r.status}${created == null ? '' : ' created $created'}',
      );
    }
    WebResponse response(ResponseBody body) => WebResponse(
      status: r.status,
      created: created,
      refusedBecause: ok || text == null
          ? null
          : _word(credential?.refusedBecause?.read(text)),
      body: body,
      redirects: List.unmodifiable(redirects),
    );
    // A body that can't be kept still leaves the status and created id the
    // site answered with, so those are what was done.
    return switch (_keep(ok ? request.keep : BodyToKeep.none, bytes)) {
      Ran(output: final kept) => Ran(response(kept)),
      NothingRan(:final why) || StoppedPartway(:final why) => StoppedPartway(
        why: '${redirects.lastOrNull ?? request.origin}: $why',
        done: response(const NoBody()),
      ),
    };
  }

  static const _redirects = {301, 302, 303, 307, 308};

  /// What of [bytes] to keep, as [keep] asks; [bytes] is null when the body
  /// ran past [maxBodyBytes].
  Outcome<ResponseBody> _keep(BodyToKeep keep, Uint8List? bytes) =>
      switch ((keep, bytes)) {
        (BodyToKeep.none, _) => const Ran(NoBody()),
        (_, null) => StoppedPartway(
          why: 'body over $maxBodyBytes bytes',
          done: null,
        ),
        (BodyToKeep.text, final kept?) => _utf8(kept),
        (BodyToKeep.bytes, final kept?) => Ran(BytesBody(kept)),
      };

  /// [bytes] as text; `utf8.decode` drops a leading byte order mark, so it
  /// is put back to keep the exact text.
  static Outcome<ResponseBody> _utf8(Uint8List bytes) {
    final bom =
        bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf;
    try {
      return Ran(TextBody('${bom ? '\u{feff}' : ''}${utf8.decode(bytes)}'));
    } on FormatException {
      return const StoppedPartway(why: 'body is not UTF-8', done: null);
    }
  }

  /// What went wrong, without the address: an [HttpException] prints its
  /// uri, query and all, and a redirect's query can be a download's token.
  static String _failure(IOException e) => switch (e) {
    HttpException(:final message) ||
    SocketException(:final message) ||
    TlsException(:final message) => message,
    _ => '${e.runtimeType}',
  };

  /// The path prefixes [credential] is pinned to on [origin], for a refusal.
  static String _pins(Credential credential, Origin origin) =>
      credential.pathPrefixes[origin]?.join(' ') ?? '/';

  /// [url]'s site, or null when it is not an http(s) one.
  static Origin? _origin(Uri url) => Origin.parse(
    Uri(scheme: url.scheme, host: url.host, port: url.port).toString(),
  );

  /// The authorization header's value for [credential]; throws
  /// [_TokenRefused] when the sign-in service will not issue a token.
  Future<String> _authorization(SignIn signIn, Credential credential) async {
    switch (credential) {
      case BearerToken(:final authorization):
        return authorization;
      case ClientCredentials():
        final cached = _tokens[signIn];
        if (cached != null) {
          final token = await cached;
          if (_now().isBefore(token.until)) return 'Bearer ${token.value}';
          if (identical(_tokens[signIn], cached)) _tokens.remove(signIn);
        }
        final fetching = _tokens[signIn] ??= _clientCredentialsToken(
          credential,
        );
        try {
          return 'Bearer ${(await fetching).value}';
        } on _TokenRefused {
          if (identical(_tokens[signIn], fetching)) _tokens.remove(signIn);
          rethrow;
        }
    }
  }

  /// Fetched again five minutes before it would expire, so a call never
  /// carries one that lapses in flight.
  Future<_Token> _clientCredentialsToken(ClientCredentials app) async {
    final HttpResult r;
    try {
      r = await _http(
        'POST',
        app.tokenUrl,
        {'content-type': 'application/x-www-form-urlencoded'},
        app.tokenForm,
        _maxTokenBytes,
      );
    } on IOException catch (e) {
      throw _TokenRefused('token: ${_failure(e)}');
    } on TimeoutException {
      throw _TokenRefused('token: timed out');
    }
    final bytes = r.body;
    if (bytes == null) throw _TokenRefused('token: reply too large');
    final body = utf8.decode(bytes, allowMalformed: true);
    if (r.status != 200) {
      // A refusal's body is the service's error, never the token: a 200's
      // body is not logged, since that is where the token is.
      _log('token from ${app.tokenUrl.host} ${r.status}: ${_clip(body)}');
      final error = _word(_oauthError.read(body));
      throw _TokenRefused(
        'token: ${r.status}${error == null ? '' : ' $error'}',
      );
    }
    return switch (_json(body)) {
      {'access_token': final String value, 'expires_in': final int seconds} =>
        _Token(
          value,
          _now().add(Duration(seconds: seconds) - const Duration(minutes: 5)),
        ),
      _ => throw _TokenRefused('token: unreadable reply'),
    };
  }

  /// OAuth 2's error code (RFC 6749, 5.2), such as `invalid_client`: the
  /// protocol's own, so every token service gives it.
  static final _oauthError = ReplyField.parse('error')!;

  /// A reason short enough to keep for good; a field that holds more than a
  /// word or two was named by mistake.
  static String? _word(String? reason) => reason == null
      ? null
      : reason.length <= 200
      ? reason
      : '${reason.substring(0, 200)}…';

  /// [Request.path] appended to its origin, or null when the result names
  /// another site. [WebPath] already cannot, so this is the backstop for the
  /// one place a secret would follow the request somewhere it was not
  /// decided to go.
  static Uri? _url(ProposedRequest request) {
    final url = Uri.tryParse('${request.origin}${request.path.value}');
    if (url == null || Origin.parse(url.origin) != request.origin) return null;
    return url;
  }

  static Object? _json(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }
}

final class _Token {
  _Token(this.value, this.until);
  final String value;
  final DateTime until;
}

final class _TokenRefused implements Exception {
  _TokenRefused(this.why);
  final String why;

  @override
  String toString() => why;
}

/// [HttpCall] over `dart:io`, giving up after ten seconds without progress.
/// A redirect is answered, not followed: the driver decides which to
/// follow, since `dart:io` would send the request to any site and the
/// logbook would not show it.
Future<HttpResult> httpCall(
  String method,
  Uri url,
  Map<String, String> headers,
  String body,
  int maxBytes,
) async {
  const quiet = Duration(seconds: 10);
  final client = HttpClient()..connectionTimeout = quiet;
  try {
    final req = await client.openUrl(method, url)
      ..followRedirects = false;
    headers.forEach(req.headers.set);
    req.add(utf8.encode(body));
    final res = await req.close().timeout(quiet);
    final location = res.headers.value(HttpHeaders.locationHeader);
    final read = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(quiet)) {
      read.add(chunk);
      if (read.length > maxBytes) {
        return (
          status: res.statusCode,
          body: null,
          location: location == null ? null : Uri.tryParse(location),
        );
      }
    }
    return (
      status: res.statusCode,
      body: read.takeBytes(),
      location: location == null ? null : Uri.tryParse(location),
    );
  } finally {
    client.close(force: true);
  }
}
