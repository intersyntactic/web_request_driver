import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_web_request_driver/is_web_request_driver.dart';
import 'package:test/test.dart';

final myUid = int.parse(
  (Process.runSync('id', ['-u']).stdout as String).trim(),
);
final me = UserId.parse(myUid)!;

final wholeSite = PathPrefix.parse('/')!;

/// [proposed] granted the whole of its site, as a rule naming no path
/// grants it.
GrantedRequest grantedWholeSite(ProposedRequest proposed) =>
    GrantedRequest.under(proposed, wholeSite);

/// A Unix socket in a folder of its own, removed when the test ends. A
/// Unix socket's path is short on macOS, so not under the test's own temp
/// directory.
Future<File> freshSocket() async {
  final dir = await Directory('/tmp').createTemp('wd');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}/s');
}

/// The caller's side of the socket, as the airlock holds its own: one
/// request in is_effects' JSON, then one answer line.
final class CallerOverSocket implements CarriesOutWebRequests {
  CallerOverSocket(this.socket);

  final File socket;

  @override
  Future<Outcome<WebResponse>> carryOutWebRequest(
    GrantedRequest request,
  ) async {
    try {
      final s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      s.add(utf8.encode(jsonEncode(encodeGrantedRequest(request))));
      await s.close();
      final answer = await utf8.decoder.bind(s).join();
      if (answer.isEmpty) return const NothingRan('refused caller');
      return decodeOutcome(jsonDecode(answer), decodeWebResponse);
    } on SocketException catch (e) {
      return StoppedPartway(why: e.message, done: null);
    }
  }
}

/// Starts a [WebRequestDriver] for this process's user on a fresh socket,
/// closed when the test ends, and returns a caller of it, so every request
/// and answer crosses the wire.
Future<CarriesOutWebRequests> startDriver(
  Map<SignIn, Credential> signIns, {
  HttpCall? http,
  DateTime Function()? now,
  void Function(String line)? log,
  int maxBodyBytes = WebRequestDriver.defaultMaxBodyBytes,
}) async {
  final socket = await freshSocket();
  final driver = await WebRequestDriver.start(
    signIns,
    caller: me,
    socket: socket,
    http: http,
    now: now,
    log: log,
    maxBodyBytes: maxBodyBytes,
  );
  addTearDown(driver.close);
  return CallerOverSocket(socket);
}
