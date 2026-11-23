import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';

/// Looks at the driver on the other end of a connected socket, such as which
/// release the kernel says it is, before any request is written to it.
/// Returns why to refuse it, or null to go on.
typedef CheckDriver = Future<String?> Function(Socket driver);

/// [CarriesOutWebRequests] in another process: passes each request to the
/// `WebRequestDriver` listening at [socket]. Holds no secret.
final class WebRequestDriverSocket implements CarriesOutWebRequests {
  /// [checkDriver] runs on every connection before the request is sent, so
  /// a driver it refuses never sees the request.
  WebRequestDriverSocket(this.socket, {this.checkDriver});

  final File socket;
  final CheckDriver? checkDriver;

  @override
  Future<Outcome<WebResponse>> carryOutWebRequest(Request request) async {
    try {
      final s = await Socket.connect(
        InternetAddress(socket.path, type: InternetAddressType.unix),
        0,
      );
      if (await checkDriver?.call(s) case final why?) {
        s.destroy();
        return Refused('web request driver: $why');
      }
      s.add(utf8.encode(jsonEncode(encodeRequest(request))));
      await s.close();
      final answer = await utf8.decoder.bind(s).join();
      if (answer.isEmpty) {
        return const Refused('web request driver: refused caller');
      }
      return decodeOutcome(jsonDecode(answer), decodeWebResponse);
    } on SocketException catch (e) {
      return Refused('web request driver: ${e.message}');
    } on FormatException catch (e) {
      return Refused('web request driver: unreadable answer: ${e.message}');
    }
  }
}
