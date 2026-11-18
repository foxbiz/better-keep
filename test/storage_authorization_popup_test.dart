@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:better_keep/services/external_sync/storage_authorization.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:web/web.dart' as web;

void main() {
  late StorageAuthorizationClient client;
  late JSAny? originalOpen;
  late web.HTMLBaseElement base;
  String? originalBase;
  late JSObject popup;
  String? openedUrl;
  String? openedFeatures;
  var blocked = false;
  var closedByApp = false;

  setUp(() {
    originalOpen = web.window.getProperty<JSAny?>('open'.toJS);
    final existing = web.document.querySelector('base') as web.HTMLBaseElement?;
    originalBase = existing?.href;
    base = existing ?? web.HTMLBaseElement();
    base.href = 'https://test.invalid/app/';
    if (existing == null) web.document.head!.append(base);
    popup = JSObject();
    popup.setProperty('closed'.toJS, false.toJS);
    popup.setProperty(
      'close'.toJS,
      (() {
        closedByApp = true;
        popup.setProperty('closed'.toJS, true.toJS);
      }).toJS,
    );
    openedUrl = null;
    openedFeatures = null;
    blocked = false;
    closedByApp = false;
    web.window.setProperty(
      'open'.toJS,
      ((String url, String target, String features) {
        openedUrl = url;
        openedFeatures = features;
        return blocked ? null : popup;
      }).toJS,
    );
    client = StorageAuthorizationClient(
      createClient: () => MockClient((_) async {
        fail('No token request is allowed without a validated callback');
      }),
    );
  });

  tearDown(() {
    client.dispose();
    web.window.setProperty('open'.toJS, originalOpen);
    if (originalBase == null) {
      base.remove();
    } else {
      base.href = originalBase!;
    }
  });

  final needsClient = dropboxStorageClientId.isEmpty
      ? 'Run with --dart-define=DROPBOX_CLIENT_ID=synthetic-client'
      : false;

  test('localhost development opens Dropbox with the exact callback', () async {
    base.href = 'http://localhost:63630/';
    final flow = await client.prepare('dropbox');
    final result = flow.authorize();
    expect(
      Uri.parse(openedUrl!).queryParameters['redirect_uri'],
      'http://localhost:63630/oauth/storage/callback',
    );
    final failure = expectLater(result, throwsA(isA<SyncProviderFailure>()));
    popup.setProperty('closed'.toJS, true.toJS);
    await failure.timeout(const Duration(seconds: 3));
  }, skip: needsClient);

  test('non-local HTTP origins cannot start authorization', () async {
    for (final origin in [
      'http://example.com/',
      'http://localhost.evil.test/',
    ]) {
      base.href = origin;
      await expectLater(
        client.prepare('dropbox'),
        throwsA(isA<SyncProviderFailure>()),
      );
      expect(openedUrl, isNull);
    }
  }, skip: needsClient);

  test(
    'prepared Dropbox flow opens synchronously and detects a closed popup',
    () async {
      final flow = await client.prepare('dropbox');
      expect(openedUrl, isNull);
      final result = flow.authorize();
      // No asynchronous work may intervene before window.open from the gesture.
      expect(openedUrl, isNotNull);
      expect(openedFeatures, isEmpty);
      final uri = Uri.parse(openedUrl!);
      expect(uri.host, 'www.dropbox.com');
      expect(
        uri.queryParameters['redirect_uri'],
        'https://test.invalid/oauth/storage/callback',
      );
      expect(uri.queryParameters['token_access_type'], 'offline');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      final failure = expectLater(result, throwsA(isA<SyncProviderFailure>()));
      popup.setProperty('closed'.toJS, true.toJS);
      await failure.timeout(const Duration(seconds: 3));
      expect(closedByApp, isTrue);
    },
    skip: needsClient,
  );

  test(
    'blocked popup fails immediately without waiting for the callback',
    () async {
      blocked = true;
      final flow = await client.prepare('dropbox');
      await expectLater(flow.authorize(), throwsA(isA<SyncProviderFailure>()));
      expect(openedUrl, isNotNull);
      expect(closedByApp, isFalse);
    },
    skip: needsClient,
  );
}
