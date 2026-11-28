import 'dart:convert';
import 'dart:io';

import 'package:is_outcome_vocabulary/is_outcome_vocabulary.dart';
import 'package:is_web_request_vocabulary/is_web_request_vocabulary.dart';
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart';
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart';
import 'package:is_web_request_driver/is_web_request_driver.dart';
import 'package:test/test.dart';

import 'start_driver.dart';

final api = Origin.parse('https://api.example')!;
final bot = SignIn.parse('some-bot')!;
final token = BearerToken(
  token: 't0ken',
  origins: {api},
  created: ReplyField.parse('id'),
  refusedBecause: ReplyField.parse('error.code'),
);

/// How a refusal before anything was sent starts on the wire.
const nothingRan = '{"kind":"nothingRan"';

typedef Sent = ({
  String method,
  Uri url,
  Map<String, String> headers,
  String body,
});

void main() {
  late File socket;
  late List<Sent> sent;

  setUp(() async {
    socket = await freshSocket();
    sent = [];
  });

  /// Answers every send with 201 and the request's path as what it made,
  /// or `/refuse` with 400 and why.
  Future<HttpResult> echo(
    String method,
    Uri url,
    Map<String, String> headers,
    String body,
    int _,
  ) async {
    sent.add((method: method, url: url, headers: headers, body: body));
    final (status, reply) = url.path == '/refuse'
        ? (
            400,
            {
              'error': {'code': 'BadArgument'},
            },
          )
        : (201, {'id': url.path});
    return (
      status: status,
      body: utf8.encode(jsonEncode(reply)),
      location: null,
    );
  }

  Future<void> start({
    UserId? caller,
    void Function(String line)? log,
    SocketUserReader? socketUserReader,
  }) async {
    final driver = await WebRequestDriver.start(
      {bot: token},
      caller: caller ?? me,
      socket: socket,
      http: echo,
      log: log,
      socketUserReader: socketUserReader,
    );
    addTearDown(driver.close);
  }

  Future<String> raw(String request) async {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(utf8.encode(request));
    await s.close();
    return (await utf8.decoder.bind(s).join()).trim();
  }

  test('carries out a request from its caller, and answers it', () async {
    await start();
    final out = await CallerOverSocket(socket).carryOutWebRequest(
      grantedWholeSite(
        ProposedRequest(
          api,
          method: Method.post,
          path: WebPath.parse('/v3/things')!,
          signIn: bot,
          headers: {'content-type': 'application/json'},
          body: '{"a":1}',
        ),
      ),
    );
    final answer = (out as Ran<WebResponse>).output;
    expect(answer.status, 201);
    expect(answer.created, '/v3/things');
    expect(answer.refusedBecause, isNull);
    final r = sent.single;
    expect(r.method, 'POST');
    expect(r.url, Uri.parse('https://api.example/v3/things'));
    expect(r.headers, {
      'content-type': 'application/json',
      'authorization': 'Bearer t0ken',
    });
    expect(r.body, '{"a":1}');
  });

  test('carries why a destination refused back across the socket', () async {
    await start();
    final out = await CallerOverSocket(socket).carryOutWebRequest(
      grantedWholeSite(
        ProposedRequest(api, path: WebPath.parse('/refuse')!, signIn: bot),
      ),
    );
    final answer = (out as Ran<WebResponse>).output;
    expect(answer.status, 400);
    expect(answer.refusedBecause, 'BadArgument');
  });

  test('answers no one but its caller, and carries out nothing', () async {
    final lines = <String>[];
    await start(caller: UserId.parse(myUid + 1), log: lines.add);
    // Closed unanswered, so the caller hears no outcome; that nothing was
    // sent is what shows nothing ran.
    await expectLater(
      CallerOverSocket(socket)
          .carryOutWebRequest(grantedWholeSite(ProposedRequest(api))),
      throwsA(isA<NoAnswer>()),
    );
    expect(sent, isEmpty);
    expect(lines, [
      'refused a caller: not allowed: user $myUid is not one of {${myUid + 1}}',
    ]);
  });

  test('refuses a caller whose user it cannot read, and says why', () async {
    final lines = <String>[];
    await start(
      log: lines.add,
      socketUserReader: SocketUserReader(kernel: Kernel.other),
    );
    await expectLater(
      CallerOverSocket(socket)
          .carryOutWebRequest(grantedWholeSite(ProposedRequest(api))),
      throwsA(isA<NoAnswer>()),
    );
    expect(sent, isEmpty);
    expect(lines, [
      'refused a caller: unread: '
          'peer credentials are only read on Linux and macOS',
    ]);
  });

  test('refuses a request carrying a credential', () async {
    await start();
    final answer = await raw(
      jsonEncode({
        'origin': 'https://api.example',
        'method': 'get',
        'path': '',
        'grantedPathPrefix': '/',
        'headers': {'Authorization': 'Bearer stolen'},
      }),
    );
    expect(answer, startsWith(nothingRan));
    expect(answer, contains('headers'));
    expect(sent, isEmpty);
  });

  // HTTP sends one of two names that differ only in case, so the airlock
  // could check one value while the other is sent.
  test('refuses a request naming one header twice, ignoring case', () async {
    await start();
    final answer = await raw(
      jsonEncode({
        'origin': 'https://api.example',
        'method': 'get',
        'path': '',
        'grantedPathPrefix': '/',
        'headers': {'content-type': 'text/plain', 'Content-Type': 'text/html'},
      }),
    );
    expect(answer, startsWith(nothingRan));
    expect(answer, contains('already named'));
    expect(sent, isEmpty);
  });

  // A request with no grant is refused rather than read as `/`.
  test('refuses a request carrying no grant', () async {
    await start();
    final answer = await raw(
      jsonEncode({
        'origin': 'https://api.example',
        'method': 'get',
        'path': '/a',
        'headers': <String, String>{},
      }),
    );
    expect(answer, startsWith(nothingRan));
    expect(answer, contains('grantedPathPrefix: missing'));
    expect(sent, isEmpty);
  });

  test('refuses a request whose path its grant does not cover', () async {
    await start();
    final answer = await raw(
      jsonEncode({
        'origin': 'https://api.example',
        'method': 'get',
        'path': '/b/x',
        'grantedPathPrefix': '/a/',
        'headers': <String, String>{},
      }),
    );
    expect(answer, startsWith(nothingRan));
    expect(answer, contains('not under'));
    expect(sent, isEmpty);
  });

  test('refuses what is not a request', () async {
    await start();
    for (final bad in ['nope', '{}', '{"origin":"ftp://x","method":"get"}']) {
      expect(await raw(bad), startsWith(nothingRan));
    }
    expect(sent, isEmpty);
  });

  // A path cannot be built that names another site, but the socket carries
  // text, which never went through WebPath.
  test('refuses a path that would name another site', () async {
    await start();
    for (final path in ['@evil.example/x', '//evil.example/x', '/a/../b']) {
      final answer = await raw(
        jsonEncode({
          'origin': 'https://api.example',
          'method': 'get',
          'path': path,
          'grantedPathPrefix': '/',
          'signIn': 'some-bot',
          'headers': <String, String>{},
        }),
      );
      expect(answer, startsWith(nothingRan));
    }
    expect(sent, isEmpty);
  });

  test('refuses a request too large to be one', () async {
    await start();
    final answer = await raw('x' * (WebRequestDriver.maxRequest + 1));
    expect(answer, startsWith(nothingRan));
    expect(answer, contains('request too large'));
    expect(sent, isEmpty);
  });

  test('replaces a socket file nothing listens on', () async {
    socket.writeAsStringSync('');
    await start();
    expect(
      await CallerOverSocket(socket)
          .carryOutWebRequest(grantedWholeSite(ProposedRequest(api))),
      isA<Ran<WebResponse>>(),
    );
  });

  test('will not start where a driver already listens', () async {
    await start();
    await expectLater(start(), throwsStateError);
  });
}
