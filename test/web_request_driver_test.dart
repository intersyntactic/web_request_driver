import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_effects/is_effects.dart';
import 'package:is_web_request_driver/is_web_request_driver.dart';
import 'package:test/test.dart';

final api = Origin.parse('https://api.example')!;
final bot = SignIn.parse('some-bot')!;
final app = ClientCredentials(
  tokenUrl: Uri.parse('https://auth.example/token'),
  clientId: 'app',
  secret: 's3cret',
  scope: 'https://api.example/.default',
  origins: {api},
  created: ReplyField.parse('id'),
  refusedBecause: ReplyField.parse('error.code'),
);

HttpResult answer(int status, String body, [Uri? location]) =>
    (status: status, body: utf8.encode(body), location: location);

typedef Call = ({String method, Uri url, Map<String, String> headers});

void main() {
  late List<Call> calls;
  late DateTime clock;
  late String reply;

  Iterable<Call> tokenCalls() =>
      calls.where((c) => c.url.host == 'auth.example');

  WebRequestDriver driver() => WebRequestDriver(
    {bot: app},
    now: () => clock,
    http: (method, url, headers, body, _) async {
      calls.add((method: method, url: url, headers: headers));
      if (url.host == 'auth.example') {
        expect(body, contains('client_secret=s3cret'));
        expect(body, contains('grant_type=client_credentials'));
        return answer(
          200,
          jsonEncode({
            'access_token': 'tok${calls.length}',
            'expires_in': 3600,
          }),
        );
      }
      return answer(201, reply);
    },
  );

  Request post({SignIn? signIn, String path = '/v3/things'}) => Request(
    api,
    method: Method.post,
    path: WebPath.parse(path)!,
    signIn: signIn,
    body: '{}',
  );

  setUp(() {
    calls = [];
    clock = DateTime.utc(2026, 11, 18);
    reply = '{"id":"1:abc"}';
  });

  test('signs with a client-credentials token and reads created', () async {
    final out = await driver().carryOutWebRequest(post(signIn: bot));
    final sent = (out as Ran<WebResponse>).output;
    expect(sent.status, 201);
    expect(sent.created, '1:abc');
    expect(calls.last.url.toString(), 'https://api.example/v3/things');
    expect(calls.last.headers['authorization'], 'Bearer tok1');
  });

  test('keeps a token until five minutes before it expires', () async {
    final d = driver();
    await d.carryOutWebRequest(post(signIn: bot));
    clock = clock.add(const Duration(minutes: 54));
    await d.carryOutWebRequest(post(signIn: bot));
    expect(tokenCalls(), hasLength(1));
    clock = clock.add(const Duration(minutes: 2));
    await d.carryOutWebRequest(post(signIn: bot));
    expect(tokenCalls(), hasLength(2));
  });

  test('concurrent sends share one token fetch', () async {
    final d = driver();
    await Future.wait([
      for (var i = 0; i < 5; i++) d.carryOutWebRequest(post(signIn: bot)),
    ]);
    expect(tokenCalls(), hasLength(1));
  });

  test('never shows a sign-in to a site it is not for', () async {
    final other = Request(Origin.parse('https://example.com')!, signIn: bot);
    expect(await driver().carryOutWebRequest(other), isA<Refused>());
    expect(calls, isEmpty);
  });

  test('refuses a sign-in it does not hold', () async {
    expect(
      await driver().carryOutWebRequest(post(signIn: SignIn.parse('nobody')!)),
      isA<Refused>(),
    );
    expect(calls, isEmpty);
  });

  test('sends under no sign-in without a credential', () async {
    final out = await driver().carryOutWebRequest(post());
    expect((out as Ran<WebResponse>).output.created, isNull);
    expect(calls.single.headers, isNot(contains('authorization')));
  });

  test('a refusal from the destination still ran, and made nothing', () async {
    final d = WebRequestDriver(
      {bot: app},
      now: () => clock,
      http: (_, url, _, _, _) async => url.host == 'auth.example'
          ? answer(200, '{"access_token":"t","expires_in":3600}')
          : answer(403, '{"id":"x"}'),
    );
    final sent = ((await d.carryOutWebRequest(
      post(signIn: bot),
    )) as Ran<WebResponse>).output;
    expect(sent.status, 403);
    expect(sent.created, isNull);
  });

  test(
    'says why the destination refused, in the outcome and the log',
    () async {
      final log = <String>[];
      final d = WebRequestDriver(
        {bot: app},
        now: () => clock,
        log: log.add,
        http: (_, url, _, _, _) async => url.host == 'auth.example'
            ? answer(200, '{"access_token":"t0ken","expires_in":3600}')
            : answer(
                404,
                '{"error":{"code":"ConversationNotFound",'
                '"message":"Conversation 19:abc@thread not found"}}',
              ),
      );
      final sent = ((await d.carryOutWebRequest(
        post(signIn: bot),
      )) as Ran<WebResponse>).output;
      // The word the sign-in names, for the logbook; the rest only logged.
      expect(sent.refusedBecause, 'ConversationNotFound');
      expect(log.single, contains('19:abc@thread'));
      expect(sent.created, isNull);
      expect(log.single, contains('404'));
      expect(log.single, contains('ConversationNotFound'));
      expect(log.single, isNot(contains('t0ken')));
    },
  );

  test('logs why a token was refused, never the secret', () async {
    final log = <String>[];
    final d = WebRequestDriver(
      {bot: app},
      log: log.add,
      http: (_, _, _, _, _) async =>
          answer(401, '{"error":"invalid_client","error_codes":[7000215]}'),
    );
    final out = await d.carryOutWebRequest(post(signIn: bot));
    // OAuth's own error code for the logbook; Microsoft's number only logged.
    expect((out as Refused).why, contains('invalid_client'));
    expect(out.why, isNot(contains('7000215')));
    expect(out.why, isNot(contains('s3cret')));
    expect(log.single, contains('7000215'));
    expect(log.single, isNot(contains('s3cret')));
  });

  test(
    'logs one line for a send that succeeds, never its path or body',
    () async {
      final log = <String>[];
      final d = WebRequestDriver(
        {bot: app},
        now: () => clock,
        log: log.add,
        http: (_, url, _, _, _) async => url.host == 'auth.example'
            ? answer(200, '{"access_token":"t0ken","expires_in":3600}')
            : answer(201, '{"id":"1","name":"private"}'),
      );
      await d.carryOutWebRequest(
        post(signIn: bot, path: '/v3/conversations/19:abc/activities'),
      );
      expect(log.single, 'POST https://api.example as some-bot 201 created 1');
      expect(log.single, isNot(contains('19:abc')));
      expect(log.single, isNot(contains('private')));
      expect(log.single, isNot(contains('t0ken')));
    },
  );

  test('a token the sign-in service refuses is a refusal', () async {
    final d = WebRequestDriver({
      bot: app,
    }, http: (_, _, _, _, _) async => answer(401, '{}'));
    final out = await d.carryOutWebRequest(post(signIn: bot));
    expect((out as Refused).why, isNot(contains('s3cret')));
  });

  test('a token request that drops never names its address', () async {
    final d = WebRequestDriver(
      {
        bot: ClientCredentials(
          tokenUrl: Uri.parse('https://auth.example/token?key=SECRET'),
          clientId: 'app',
          secret: 's3cret',
          scope: 'https://api.example/.default',
          origins: {api},
        ),
      },
      http: (_, url, _, _, _) async =>
          throw HttpException('Connection reset', uri: url),
    );
    final out = await d.carryOutWebRequest(post(signIn: bot));
    final why = (out as Refused).why;
    expect(why, contains('Connection reset'));
    expect(why, isNot(contains('SECRET')));
  });

  group('bodies and redirects', () {
    final files = Origin.parse('https://files.example')!;
    final reader = ClientCredentials(
      tokenUrl: Uri.parse('https://auth.example/token'),
      clientId: 'app',
      secret: 's3cret',
      scope: 'https://api.example/.default',
      origins: {api, files},
    );
    late Map<String, HttpResult> site;
    late Set<String> drops;
    late List<String> log;

    WebRequestDriver reading({int maxBodyBytes = 1 << 20}) => WebRequestDriver(
      {bot: reader},
      now: () => clock,
      log: log.add,
      maxBodyBytes: maxBodyBytes,
      http: (method, url, headers, body, maxBytes) async {
        calls.add((method: method, url: url, headers: headers));
        if (url.host == 'auth.example') {
          return answer(200, '{"access_token":"t0ken","expires_in":3600}');
        }
        if (drops.contains('$method $url')) {
          throw HttpException(
            'Connection closed before full header was received',
            uri: url,
          );
        }
        final r = site['$method $url'] ?? answer(404, 'no such page');
        final read = r.body;
        return read != null && read.length > maxBytes
            ? (status: r.status, body: null, location: r.location)
            : r;
      },
    );

    Request get(
      String path, {
      BodyToKeep keep = BodyToKeep.text,
      PathPrefix? granted,
    }) => Request(
      api,
      path: WebPath.parse(path)!,
      grantedPathPrefix: granted,
      signIn: bot,
      headers: {'accept': '*/*'},
      keep: keep,
    );

    HttpResult redirect(String to) => answer(302, '', Uri.parse(to));

    Future<WebResponse> ran(Future<Outcome<WebResponse>> out) async =>
        ((await out) as Ran<WebResponse>).output;

    setUp(() {
      site = {};
      drops = {};
      log = [];
    });

    test('keeps a 2xx body as text when asked', () async {
      site['GET https://api.example/a'] = answer(200, 'héllo');
      final r = await ran(reading().carryOutWebRequest(get('/a')));
      expect((r.body as TextBody).text, 'héllo');
      expect(r.redirects, isEmpty);
    });

    test('keeps a body as its exact bytes', () async {
      final zip = Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, 0xff, 0x00]);
      site['GET https://api.example/a'] = (
        status: 200,
        body: zip,
        location: null,
      );
      final r = await ran(
        reading().carryOutWebRequest(get('/a', keep: BodyToKeep.bytes)),
      );
      expect((r.body as BytesBody).bytes, zip);
    });

    test('keeps nothing unless asked, and nothing of a non-2xx', () async {
      site['GET https://api.example/a'] = answer(200, 'kept?');
      site['GET https://api.example/b'] = answer(500, 'error page');
      final d = reading();
      final none = await ran(
        d.carryOutWebRequest(get('/a', keep: BodyToKeep.none)),
      );
      final failed = await ran(d.carryOutWebRequest(get('/b')));
      expect(none.body, isA<NoBody>());
      expect(failed.body, isA<NoBody>());
      expect(failed.status, 500);
    });

    test('keeps a leading byte order mark in a text body', () async {
      site['GET https://api.example/a'] = (
        status: 200,
        body: Uint8List.fromList([0xef, 0xbb, 0xbf, ...utf8.encode('hi')]),
        location: null,
      );
      final r = await ran(reading().carryOutWebRequest(get('/a')));
      expect((r.body as TextBody).text, '\u{feff}hi');
    });

    test('refuses text that is not UTF-8', () async {
      site['GET https://api.example/a'] = (
        status: 200,
        body: Uint8List.fromList([0xff, 0xfe]),
        location: null,
      );
      final out = await reading().carryOutWebRequest(get('/a'));
      expect((out as Refused).why, contains('not UTF-8'));
    });

    test('refuses to keep a body over the limit', () async {
      site['GET https://api.example/a'] = answer(200, 'x' * 11);
      final out = await reading(maxBodyBytes: 10)
          .carryOutWebRequest(get('/a', keep: BodyToKeep.bytes));
      expect((out as Refused).why, contains('over 10 bytes'));
    });

    test('a large body it was not asked to keep still ran', () async {
      site['POST https://api.example/a'] = answer(201, 'x' * 11);
      final r = await ran(
        reading(maxBodyBytes: 10).carryOutWebRequest(
          Request(
            api,
            method: Method.post,
            path: WebPath.parse('/a')!,
            signIn: bot,
          ),
        ),
      );
      expect(r.status, 201);
      expect(r.body, isA<NoBody>());
    });

    test(
      'follows a redirect to a site the sign-in is for, without its secret',
      () async {
        site['GET https://api.example/a'] = redirect(
          'https://files.example/f.docx?tempauth=SECRET',
        );
        site['GET https://files.example/f.docx?tempauth=SECRET'] = answer(
          200,
          'the file',
        );
        final r = await ran(reading().carryOutWebRequest(get('/a')));
        expect((r.body as TextBody).text, 'the file');
        expect(r.redirects.map((h) => '$h'), ['https://files.example/f.docx']);
        final hop = calls.last;
        expect(hop.url.host, 'files.example');
        expect(hop.headers, isNot(contains('authorization')));
        expect(hop.headers['accept'], '*/*');
      },
    );

    test('keeps the sign-in on a redirect within its own site', () async {
      site['GET https://api.example/a'] = redirect('/b');
      site['GET https://api.example/b'] = answer(200, 'moved');
      final r = await ran(reading().carryOutWebRequest(get('/a')));
      expect(r.redirects.map((h) => '$h'), ['https://api.example/b']);
      expect(calls.last.headers['authorization'], 'Bearer t0ken');
    });

    test('refuses a redirect to a site the sign-in is not for', () async {
      site['GET https://api.example/a'] = redirect('https://evil.example/x');
      final out = await reading().carryOutWebRequest(get('/a'));
      expect((out as Refused).why, contains('https://evil.example'));
      expect(calls.where((c) => c.url.host == 'evil.example'), isEmpty);
    });

    test('with no sign-in, follows only within the site decided', () async {
      site['GET https://api.example/a'] = redirect('https://files.example/f');
      final out = await reading().carryOutWebRequest(
        Request(api, path: WebPath.parse('/a')!),
      );
      expect(out, isA<Refused>());
      expect(calls.where((c) => c.url.host == 'files.example'), isEmpty);
    });

    test('refuses a fourth redirect', () async {
      for (final (from, to) in [
        ('a', 'b'),
        ('b', 'c'),
        ('c', 'd'),
        ('d', 'e'),
      ]) {
        site['GET https://api.example/$from'] = redirect('/$to');
      }
      site['GET https://api.example/e'] = answer(200, 'too far');
      final out = await reading().carryOutWebRequest(get('/a'));
      expect((out as Refused).why, contains('more than 3'));
    });

    group('a redirect on the request\'s own site stays under its grant', () {
      final drive = PathPrefix.parse('/v1.0/drives/d/')!;
      const content = '/v1.0/drives/d/items/i/content';

      Future<Outcome<WebResponse>> granted() =>
          reading().carryOutWebRequest(get(content, granted: drive));

      void expectNeverCalled(String path) => expect(
        calls.where((c) => c.url.host == 'api.example' && c.url.path == path),
        isEmpty,
      );

      test('follows a hop within the grant, its query and all', () async {
        site['GET https://api.example$content'] = redirect(
          '/v1.0/drives/d/items/i/raw?sig=a@b..c',
        );
        site['GET https://api.example/v1.0/drives/d/items/i/raw?sig=a@b..c'] =
            answer(200, 'the file');
        final r = await ran(granted());
        expect((r.body as TextBody).text, 'the file');
      });

      test(
        'refuses a hop out of the grant, naming only site and prefix',
        () async {
          site['GET https://api.example$content'] = redirect(
            '/v1.0/drives/other/x?tempauth=SECRET',
          );
          final out = await granted();
          final why = (out as Refused).why;
          expect(why, contains('https://api.example'));
          expect(why, contains('/v1.0/drives/d/'));
          expect(why, isNot(contains('SECRET')));
          expect(why, isNot(contains('other')));
          expect(log.join('\n'), isNot(contains('SECRET')));
          expectNeverCalled('/v1.0/drives/other/x');
        },
      );

      test('refuses escaped dot segments that resolve out of it', () async {
        site['GET https://api.example$content'] = redirect(
          '/v1.0/drives/d/%2e%2e/%2E%2E/other/x',
        );
        expect(await granted(), isA<Refused>());
        expectNeverCalled('/v1.0/other/x');
      });

      test('refuses a path a server could decode twice', () async {
        site['GET https://api.example$content'] = redirect(
          '/v1.0/drives/d/%252e%252e/x',
        );
        expect(await granted(), isA<Refused>());
        expectNeverCalled('/v1.0/drives/d/%252e%252e/x');
      });

      test('leaves a hop to another site to the sign-in', () async {
        site['GET https://api.example$content'] = redirect(
          'https://files.example/f?tempauth=SECRET',
        );
        site['GET https://files.example/f?tempauth=SECRET'] = answer(200, 'f');
        final r = await ran(granted());
        expect((r.body as TextBody).text, 'f');
      });

      test('holds on a hop back from another site', () async {
        site['GET https://api.example$content'] = redirect(
          'https://files.example/f',
        );
        site['GET https://files.example/f'] = redirect(
          'https://api.example/v1.0/drives/other/x',
        );
        expect(await granted(), isA<Refused>());
        expectNeverCalled('/v1.0/drives/other/x');
      });

      test('reads a hop to the bare site as its root', () async {
        site['GET https://api.example/a'] = redirect('https://api.example?x=1');
        site['GET https://api.example?x=1'] = answer(200, 'home');
        final whole = await ran(
          reading().carryOutWebRequest(
            get('/a', granted: PathPrefix.parse('/')!),
          ),
        );
        expect((whole.body as TextBody).text, 'home');
        site['GET https://api.example$content'] = redirect(
          'https://api.example',
        );
        expect(await granted(), isA<Refused>());
      });
    });

    test('answers a redirect to anything but a GET', () async {
      site['POST https://api.example/a'] = answer(
        303,
        '',
        Uri.parse('https://files.example/f'),
      );
      final r = await ran(
        reading().carryOutWebRequest(
          Request(
            api,
            method: Method.post,
            path: WebPath.parse('/a')!,
            signIn: bot,
          ),
        ),
      );
      expect(r.status, 303);
      expect(r.redirects, isEmpty);
      expect(calls.where((c) => c.url.host == 'files.example'), isEmpty);
    });

    test('never logs where a redirect led beyond its path', () async {
      site['GET https://api.example/a'] = redirect(
        'https://files.example/f?tempauth=SECRET',
      );
      site['GET https://files.example/f?tempauth=SECRET'] = answer(403, 'no');
      await reading().carryOutWebRequest(get('/a'));
      expect(log.single, contains('https://files.example/f'));
      expect(log.single, isNot(contains('SECRET')));
    });

    test(
      'a connection dropped after a redirect never names its query',
      () async {
        site['GET https://api.example/a'] = redirect(
          'https://files.example/f?tempauth=SECRET',
        );
        drops.add('GET https://files.example/f?tempauth=SECRET');
        final out = await reading().carryOutWebRequest(get('/a'));
        final why = (out as Refused).why;
        expect(why, contains('https://files.example'));
        expect(why, contains('Connection closed'));
        expect(why, isNot(contains('SECRET')));
        expect(log.single, contains('https://files.example/f'));
        expect(log.single, isNot(contains('SECRET')));
      },
    );
  });

  group('Credential', () {
    final file = {
      'kind': 'client-credentials',
      'tokenUrl': 'https://auth.example/token',
      'clientId': 'a',
      'secret': 's3cret',
      'origins': ['https://api.example'],
      'created': 'id',
      'refusedBecause': 'error.code',
    };

    test('loads one file per sign-in', () async {
      final dir = await Directory.systemTemp.createTemp('creds');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/some-bot').writeAsString(jsonEncode(file));
      final loaded = await Credential.load(dir);
      expect(loaded[bot]?.origins, {api});
      expect(loaded[bot]?.created?.read('{"id":"1"}'), '1');
      expect(
        loaded[bot]?.refusedBecause?.read('{"error":{"code":"BadArgument"}}'),
        'BadArgument',
      );
    });

    for (final (why, broken) in [
      ('no secret', {...file}..remove('secret')),
      ('no origins', {...file, 'origins': <String>[]}),
      (
        'an origin with a path',
        {
          ...file,
          'origins': ['https://a.example/x'],
        },
      ),
      ('a token url in the clear', {...file, 'tokenUrl': 'http://a.example'}),
      ('a field path with an empty key', {...file, 'refusedBecause': 'a..b'}),
    ]) {
      test('refuses $why, never naming the secret', () {
        expect(
          () => Credential.parse(jsonEncode(broken)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              isNot(contains('s3cret')),
            ),
          ),
        );
      });
    }
  });
}
