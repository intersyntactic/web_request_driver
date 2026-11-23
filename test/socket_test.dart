import 'dart:convert';
import 'dart:io';

import 'package:is_effects/is_effects.dart';
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

  Future<void> start({UserId? caller}) async {
    final driver = await WebRequestDriver.start(
      {bot: token},
      caller: caller ?? me,
      socket: socket,
      http: echo,
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
    final out = await WebRequestDriverSocket(socket).carryOutWebRequest(
      Request(
        api,
        method: Method.post,
        path: WebPath.parse('/v3/things')!,
        signIn: bot,
        headers: {'content-type': 'application/json'},
        body: '{"a":1}',
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
    final out = await WebRequestDriverSocket(socket).carryOutWebRequest(
      Request(api, path: WebPath.parse('/refuse')!, signIn: bot),
    );
    final answer = (out as Ran<WebResponse>).output;
    expect(answer.status, 400);
    expect(answer.refusedBecause, 'BadArgument');
  });

  // The answer from a driver before is_effects' wire format: never guessed
  // at, so a driver and airlock deployed out of step fail loudly.
  test('an answer it cannot read is a refusal', () async {
    final server = await ServerSocket.bind(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    addTearDown(server.close);
    server.listen((s) async {
      await s.drain<void>();
      s.write('{"ran":{"status":201,"created":"1:abc"}}\n');
      await s.close();
    });
    final out = await WebRequestDriverSocket(socket)
        .carryOutWebRequest(Request(api));
    expect((out as Refused).why, contains('unreadable answer'));
  });

  test('answers no one but its caller, and carries out nothing', () async {
    await start(caller: UserId.parse(myUid + 1));
    final out = await WebRequestDriverSocket(socket)
        .carryOutWebRequest(Request(api));
    expect(out, isA<Refused>());
    expect(sent, isEmpty);
  });

  test('refuses a request carrying a credential', () async {
    await start();
    final answer = await raw(
      jsonEncode({
        'origin': 'https://api.example',
        'method': 'get',
        'path': '',
        'headers': {'Authorization': 'Bearer stolen'},
      }),
    );
    expect(answer, contains('refused'));
    expect(sent, isEmpty);
  });

  test('refuses what is not a request', () async {
    await start();
    for (final bad in ['nope', '{}', '{"origin":"ftp://x","method":"get"}']) {
      expect(await raw(bad), contains('refused'));
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
          'signIn': 'some-bot',
          'headers': <String, String>{},
        }),
      );
      expect(answer, contains('refused'));
    }
    expect(sent, isEmpty);
  });

  test('refuses a request too large to be one', () async {
    await start();
    final answer = await raw('x' * (WebRequestDriver.maxRequest + 1));
    expect(answer, contains('request too large'));
    expect(sent, isEmpty);
  });

  test('a driver the check refuses never sees the request', () async {
    await start();
    final out = await WebRequestDriverSocket(
      socket,
      checkDriver: (_) async => 'not the release it should be',
    ).carryOutWebRequest(Request(api));
    expect((out as Refused).why, contains('not the release it should be'));
    expect(sent, isEmpty);
  });

  test('a driver the check passes carries out the request', () async {
    await start();
    var checked = 0;
    final out = await WebRequestDriverSocket(
      socket,
      checkDriver: (_) async {
        checked++;
        return null;
      },
    ).carryOutWebRequest(Request(api));
    expect(out, isA<Ran<WebResponse>>());
    expect(checked, 1);
    expect(sent, hasLength(1));
  });

  test('says so when no service is listening', () async {
    expect(
      await WebRequestDriverSocket(socket).carryOutWebRequest(Request(api)),
      isA<Refused>(),
    );
  });

  test('replaces a socket file nothing listens on', () async {
    socket.writeAsStringSync('');
    await start();
    expect(
      await WebRequestDriverSocket(socket).carryOutWebRequest(Request(api)),
      isA<Ran<WebResponse>>(),
    );
  });

  test('will not start where a driver already listens', () async {
    await start();
    await expectLater(start(), throwsStateError);
  });
}
