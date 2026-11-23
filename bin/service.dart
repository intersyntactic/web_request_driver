/// Runs the web request driver as a service (see `WebRequestDriver`):
///
///     WEB_REQUEST_DRIVER_SOCKET=/run/intersyntactic-web-driver/web-driver.sock \
///       WEB_REQUEST_DRIVER_CALLER=airlock \
///       CREDENTIALS_DIRECTORY=... \
///       dart run is_web_request_driver:service
///
/// `WEB_REQUEST_DRIVER_CALLER` is the one user, by name or id, whose requests it
/// carries out. systemd sets `CREDENTIALS_DIRECTORY` from `LoadCredential=`.
///
/// Exits 78 when it cannot start as configured, and closes cleanly on
/// SIGTERM or SIGINT.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
import 'package:is_web_request_driver/is_web_request_driver.dart';

Future<void> main() async {
  final env = Platform.environment;
  final [socket, caller, credentials] = [
    for (final name in [
      'WEB_REQUEST_DRIVER_SOCKET',
      'WEB_REQUEST_DRIVER_CALLER',
      'CREDENTIALS_DIRECTORY',
    ])
      env[name] ?? _fail('$name is not set'),
  ];
  final number = _uidOf(caller) ?? _fail('no user $caller');
  final uid =
      UserId.parse(number) ??
      _fail('$caller is uid $number, which names no single user');
  final Map<SignIn, Credential> signIns;
  try {
    signIns = await Credential.load(Directory(credentials));
  } on Exception catch (e) {
    _fail('$e');
  }
  final WebRequestDriver driver;
  try {
    driver = await WebRequestDriver.start(
      signIns,
      caller: uid,
      socket: File(socket),
      log: stdout.writeln,
    );
  } on Object catch (e) {
    _fail('$e');
  }
  stdout.writeln(
    'listening on $socket for $caller, '
    'sign-ins: ${signIns.keys.join(' ')}',
  );
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await driver.close();
  exit(0);
}

int? _uidOf(String user) {
  if (int.tryParse(user) case final uid?) return uid;
  final r = Process.runSync('id', ['-u', user]);
  return r.exitCode == 0 ? int.tryParse(r.stdout.toString().trim()) : null;
}

Never _fail(String why) {
  stderr.writeln('is_web_request_driver service: $why');
  exit(78);
}
