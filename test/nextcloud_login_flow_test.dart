import 'dart:async';
import 'dart:convert';

import 'package:better_keep/services/external_sync/nextcloud_login_flow.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final server = Uri.parse('https://cloud.example/nextcloud');
  late NextcloudLoginFlow flow;
  late DateTime clock;
  late bool current;
  late int launches;
  late Future<http.Response> Function(http.Request) handler;
  http.Response json(Object value, [int code = 200]) =>
      http.Response(jsonEncode(value), code);
  Map<String, dynamic> prepared({String? endpoint, String? login}) => {
    'poll': {
      'token': 'private+poll/token',
      'endpoint': endpoint ?? '$server/login/v2/poll',
    },
    'login': login ?? '$server/index.php/login/v2/flow/browser-token',
  };
  Map<String, dynamic> credentials({String? host}) => {
    'server': host ?? '$server/',
    'loginName': 'email@example.invalid',
    'appPassword': 'private-app-password',
  };
  http.Response user() => json({
    'ocs': {
      'meta': {'statuscode': 200},
      'data': {'id': 'canonical-user'},
    },
  });
  setUp(() {
    clock = DateTime.utc(2026, 10, 24);
    current = true;
    launches = 0;
    handler = (_) async => throw StateError('Unexpected request');
    flow = NextcloudLoginFlow(
      server: server,
      client: MockClient((request) => handler(request)),
      isCurrent: () => current,
      now: () => clock,
      pollInterval: Duration.zero,
      launch: (uri) async {
        launches++;
        expect(uri.toString(), '$server/index.php/login/v2/flow/browser-token');
        return true;
      },
    );
  });
  tearDown(() => flow.dispose());

  test('browser login polls anonymously then resolves DAV ID using the returned login', () async {
    var polls = 0;
    handler = (request) async {
      expect(request.followRedirects, false);
      if (request.url.path.endsWith('/index.php/login/v2')) {
        expect(request.method, 'POST');
        expect(request.headers['authorization'], isNull);
        return json(prepared());
      }
      if (request.url.path.endsWith('/poll')) {
        expect(request.headers['authorization'], isNull);
        expect(Uri.splitQueryString(request.body), {
          'token': 'private+poll/token',
        });
        return ++polls == 1 ? http.Response('', 404) : json(credentials());
      }
      expect(request.url.toString(), '$server/ocs/v2.php/cloud/user');
      expect(
        request.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('email@example.invalid:private-app-password'))}',
      );
      return user();
    };
    await flow.prepare();
    expect(launches, 0);
    final access = await flow.authorize();
    expect(access.username, 'email@example.invalid');
    expect(access.davUserId, 'canonical-user');
    expect(access.server, server);
    expect(access.password, 'private-app-password');
    expect(await flow.authorize(), same(access));
    expect(launches, 1);
    expect(polls, 2);
  });

  test(
    'a failed account lookup retries without consuming the one-use poll again',
    () async {
      var polls = 0, lookups = 0;
      handler = (request) async {
        if (request.url.path.endsWith('/index.php/login/v2')) {
          return json(prepared());
        }
        if (request.url.path.endsWith('/poll')) {
          polls++;
          return json(credentials());
        }
        return ++lookups == 1
            ? http.Response('private-server-error', 503)
            : user();
      };
      await flow.prepare();
      await expectLater(flow.authorize(), throwsA(isA<SyncProviderFailure>()));
      expect((await flow.authorize()).davUserId, 'canonical-user');
      expect(polls, 1);
      expect(launches, 1);
    },
  );

  for (final endpoint in [
    'https://other.example/login/v2/poll',
    'http://cloud.example/nextcloud/login/v2/poll',
    'https://cloud.example/other/login/v2/poll',
    'https://cloud.example/nextcloud/login/v2/poll?secret=x',
    'https://user:password@cloud.example/nextcloud/login/v2/poll',
  ]) {
    test('rejects an unsafe poll endpoint: $endpoint', () async {
      handler = (_) async => json(prepared(endpoint: endpoint));
      await expectLater(flow.prepare(), throwsA(isA<SyncProviderFailure>()));
      expect(launches, 0);
    });
  }

  test('rejects a browser URL outside the chosen installation', () async {
    handler = (_) async =>
        json(prepared(login: 'https://other.example/login/v2/flow/token'));
    await expectLater(flow.prepare(), throwsA(isA<SyncProviderFailure>()));
    expect(launches, 0);
  });

  test(
    'does not send returned credentials to a different server or installation',
    () async {
      var requests = 0;
      handler = (request) async {
        requests++;
        if (request.url.path.endsWith('/index.php/login/v2')) {
          return json(prepared());
        }
        return json(credentials(host: 'https://cloud.example/other'));
      };
      await flow.prepare();
      await expectLater(flow.authorize(), throwsA(isA<SyncProviderFailure>()));
      expect(requests, 2);
    },
  );

  test(
    'cancelled or replaced account ignores an in-flight credential response',
    () async {
      for (final cancel in [false, true]) {
        current = true;
        final started = Completer<void>(), result = Completer<http.Response>();
        handler = (request) async {
          if (request.url.path.endsWith('/index.php/login/v2')) {
            return json(prepared());
          }
          started.complete();
          return result.future;
        };
        await flow.prepare();
        final pending = flow.authorize();
        final rejected = expectLater(pending, throwsStateError);
        await started.future;
        if (cancel) {
          flow.dispose();
        } else {
          current = false;
        }
        result.complete(json(credentials()));
        await rejected;
      }
    },
  );

  test(
    'polling expires without reopening the browser or leaking a response',
    () async {
      var polls = 0;
      handler = (request) async {
        if (request.url.path.endsWith('/index.php/login/v2')) {
          return json(prepared());
        }
        polls++;
        clock = clock.add(const Duration(minutes: 20));
        return http.Response('', 404);
      };
      await flow.prepare();
      await expectLater(
        flow.authorize(),
        throwsA(
          isA<SyncProviderFailure>().having(
            (e) => e.kind,
            'kind',
            SyncProviderFailureKind.reconnectRequired,
          ),
        ),
      );
      expect(polls, 1);
      expect(launches, 1);
    },
  );
}
