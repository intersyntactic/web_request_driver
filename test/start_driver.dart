import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_web_request_driver/is_web_request_driver.dart';
import 'package:test/test.dart';

final myUid = int.parse(
  (Process.runSync('id', ['-u']).stdout as String).trim(),
);
final me = UserId.parse(myUid)!;

/// A Unix socket in a folder of its own, removed when the test ends. A
/// Unix socket's path is short on macOS, so not under the test's own temp
/// directory.
Future<File> freshSocket() async {
  final dir = await Directory('/tmp').createTemp('wd');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}/s');
}

/// Starts a [WebRequestDriver] for this process's user on a fresh socket,
/// closed when the test ends, and returns the airlock's side of it, so every
/// request and answer crosses the wire.
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
  return WebRequestDriverSocket(socket);
}
