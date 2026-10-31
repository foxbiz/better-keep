import 'dart:async';

import 'package:better_keep/services/external_sync/storage_usage.dart';

import 'dart:convert';

import 'package:better_keep/services/monetization/entitlements.dart';

import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/components/sync_provider_tile.dart';
import 'package:better_keep/pages/settings/storage_sync_page.dart';
import 'package:better_keep/services/external_sync/external_sync_service.dart';
import 'package:better_keep/services/external_sync/library_sync_session.dart';
import 'package:better_keep/services/external_sync/storage_connection.dart';
import 'package:better_keep/services/external_sync/storage_connection_controller.dart';
import 'package:better_keep/services/external_sync/storage_credential_broker.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_scheduler.dart';
import 'package:better_keep/services/external_sync/sync_status_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:better_keep/services/external_sync/nextcloud_login_flow.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Service service;
  late ValueNotifier<Entitlements> entitlements;
  late _Connections connections;
  late FirebaseSyncPreference selection;
  late List<String> selectionWrites;
  Completer<void>? selectionGate;
  setUp(() {
    selectionGate = null;
    selectionWrites = [];
    entitlements = ValueNotifier(Entitlements.pro);
    connections = _Connections();
    var revision = 1;
    selection = FirebaseSyncPreference(
      entitlements: entitlements,
      currentUid: () => 'owner',
      watch: (_) =>
          Stream.value(const FirebaseSyncSelection(true, confirmed: true)),
      write: (_, enabled) async =>
          FirebaseSyncSelection(enabled, confirmed: true, revision: ++revision),
      writeProvider: (_, provider) async {
        selectionWrites.add(provider);
        await selectionGate?.future;
        return FirebaseSyncSelection(
          provider == 'firebase',
          provider: provider,
          confirmed: true,
          revision: ++revision,
        );
      },
    );
    selection.bind('owner');
    service = _Service(_Session(connections));
    connections.addListener(service.notifyListeners);
  });
  tearDown(() {
    selection.dispose();
    entitlements.dispose();
    connections.dispose();
    service.dispose();
  });
  Future<void> mount(
    WidgetTester tester, {
    double textScale = 1,
    EdgeInsets viewInsets = EdgeInsets.zero,
    Locale? locale,
    FirebaseSyncPreference? preference,
  }) => tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          viewInsets: viewInsets,
        ),
        child: child!,
      ),
      home: StorageSyncPage(
        service: service,
        firebasePreference: preference ?? selection,
      ),
    ),
  );
  Finder card(String provider) => find.byKey(ValueKey('storage-$provider'));
  testWidgets('shared settings entry follows provider name and icon changes', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SyncProviderTile(
            preference: selection,
            onTap: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sync provider'), findsOneWidget);
    expect(find.text('Better Keep cloud'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    for (final entry in syncProviderOptions.entries) {
      await selection.selectProvider(entry.key);
      await tester.pumpAndSettle();
      expect(find.text(entry.value.name), findsOneWidget);
      expect(find.byIcon(entry.value.icon), findsOneWidget);
      expect(find.byIcon(Icons.cloud_outlined), findsNothing);
    }
    await selection.selectProvider('none');
    await tester.pumpAndSettle();
    expect(find.text('Sync off'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    await tester.tap(find.byType(ListTile));
    expect(opened, true);
  });
  testWidgets(
    'Lite updates the account entry and disables the built-in radio',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SyncProviderTile(preference: selection, onTap: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Better Keep cloud'), findsOneWidget);
      entitlements.value = Entitlements.lite;
      await tester.pumpAndSettle();
      expect(find.text('Sync off'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);

      await mount(tester);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
            .groupValue,
        'none',
      );
      final cloudRadio = find.descendant(
        of: card('firebase'),
        matching: find.byType(Radio<String>),
      );
      expect(tester.widget<Radio<String>>(cloudRadio).enabled, false);
      await tester.tap(card('firebase'));
      await tester.pumpAndSettle();
      expect(selection.selectedProvider, 'none');
      expect(selection.allowsSync('owner'), false);
    },
  );

  testWidgets(
    'selected connected card stays compact and does not restart sync',
    (tester) async {
      connections.values['dropbox'] = _connection('dropbox');
      await mount(tester);
      await tester.pumpAndSettle();
      await selection.selectProvider('dropbox');
      await tester.pumpAndSettle();
      selectionWrites.clear();
      final title = find.descendant(
        of: card('dropbox'),
        matching: find.text('Dropbox'),
      );
      expect(
        tester.getTopLeft(title).dy - tester.getTopLeft(card('dropbox')).dy,
        lessThanOrEqualTo(24),
      );
      await tester.ensureVisible(title);
      await tester.tap(title);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: card('dropbox'),
          matching: find.byType(Radio<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(selectionWrites, isEmpty);
      expect(connections.calls, isEmpty);
      expect(selection.selectedProvider, 'dropbox');
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> menu(WidgetTester tester, String provider, String action) async {
    final target = find.byKey(ValueKey('storage-menu-$provider'));
    await tester.scrollUntilVisible(target, 180);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
    await tester.tap(find.text(action).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'external cards say Free and full storage has actionable feedback',
    (tester) async {
      connections.values['dropbox'] = _connection('dropbox');
      (service.session!.scheduler as _Scheduler).progress['dropbox:1'] =
          const SyncConnectionProgress(
            failure: SyncProviderFailureKind.quotaExceeded,
          );
      await mount(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('Not connected · Free'), findsNWidgets(3));
      expect(
        find.textContaining('Storage full. Sync is paused'),
        findsOneWidget,
      );
      expect(find.textContaining('Requires Pro'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('connected cards replace the price label with account capacity', (
    tester,
  ) async {
    connections.values['dropbox'] = _connection('dropbox');
    connections.usage = const StorageUsage(
      freeBytes: 8200000000,
      totalBytes: 15000000000,
    );
    await mount(tester);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: card('dropbox'),
        matching: find.textContaining(' · Free'),
      ),
      findsNothing,
    );
    expect(find.text('6.8 GB used of 15 GB'), findsOneWidget);
    expect(find.text('Not connected · Free'), findsNWidgets(3));
  });

  testWidgets('clearing requires email code and confirmation before deletion', (
    tester,
  ) async {
    connections.values['dropbox'] = _connection('dropbox');
    await mount(tester);
    await tester.pumpAndSettle();
    await menu(tester, 'dropbox', 'Clear synced data');
    expect(
      find.textContaining('provider-only data will be lost'),
      findsOneWidget,
    );
    expect(connections.calls, isEmpty);
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    expect(connections.calls, ['clear-code:dropbox']);
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(connections.calls, ['clear-code:dropbox', 'clear:dropbox']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.textContaining('Synced data cleared. Sync is off.'),
      findsOneWidget,
    );
  });

  for (final scale in [1.0, 1.8]) {
    testWidgets('clear-code dialog fits with keyboard at text scale $scale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      connections.values['dropbox'] = _connection('dropbox');
      await mount(
        tester,
        textScale: scale,
        viewInsets: const EdgeInsets.only(bottom: 280),
      );
      await tester.pumpAndSettle();
      await menu(tester, 'dropbox', 'Clear synced data');
      await tester.tap(find.text('Send code'));
      await tester.pumpAndSettle();
      expect(find.text('Verify to clear'), findsOneWidget);
      expect(find.textContaining('provider-only data'), findsNothing);
      final field = find.byType(TextField);
      await tester.pumpAndSettle();
      expect(tester.getRect(field).bottom, lessThanOrEqualTo(420));
      expect(tester.getRect(field).top, greaterThanOrEqualTo(0));
      final cancel = find.widgetWithText(TextButton, 'Cancel');
      final clear = find.widgetWithText(FilledButton, 'Clear');
      expect(tester.getCenter(cancel).dy, tester.getCenter(clear).dy);
      expect(tester.getRect(clear).bottom, lessThanOrEqualTo(420));
      expect(tester.takeException(), isNull);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(connections.calls, ['clear-code:dropbox']);
    });
  }

  testWidgets('code resend waits for cooldown and never clears automatically', (
    tester,
  ) async {
    connections.values['dropbox'] = _connection('dropbox');
    await mount(tester);
    await tester.pumpAndSettle();
    await menu(tester, 'dropbox', 'Clear synced data');
    await tester.tap(find.text('Send code'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Resend code in 60s'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pump();
    expect(connections.calls, ['clear-code:dropbox']);
    await tester.pump(const Duration(seconds: 60));
    await tester.tap(find.text('Resend code'));
    await tester.pumpAndSettle();
    expect(connections.calls, ['clear-code:dropbox', 'clear-code:dropbox']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  for (final language in ['en', 'pt', 'id', 'ja', 'ko', 'tr', 'zh']) {
    testWidgets('compact cards and details fit narrow large text: $language', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final locale = Locale(language);
      final l10n = lookupAppLocalizations(locale);
      connections.values['google_drive'] = _connection('google_drive');
      (service.session!.scheduler as _Scheduler).progress['google_drive:1'] =
          const SyncConnectionProgress(
            blockedEntities: 1,
            notesRequiringUnlock: 1,
          );
      await mount(tester, locale: locale, textScale: 1.8);
      await tester.pumpAndSettle();
      expect(find.byType(Switch), findsNothing);
      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.byType(TextButton),
        ),
        findsNothing,
      );
      await menu(tester, 'google_drive', l10n.externalSyncDetails);
      expect(find.text(l10n.externalSyncUnlockSketches), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(card('nextcloud'), 250);
      await tester.ensureVisible(card('nextcloud'));
      await tester.pumpAndSettle();
      await tester.tap(card('nextcloud'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.externalSyncServer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'radio selection switches provider and preserves connected accounts',
    (tester) async {
      connections.values['google_drive'] = _connection('google_drive');
      connections.values['dropbox'] = _connection('dropbox');
      await mount(tester);
      await tester.pumpAndSettle();
      expect(selection.selectedProvider, 'firebase');
      await tester.tap(card('google_drive'));
      await tester.pumpAndSettle();
      expect(selection.selectedProvider, 'google_drive');
      expect(selection.allowsCurrentAccount, false);
      expect(selection.allowsProvider('dropbox'), false);
      await tester.tap(card('dropbox'));
      await tester.pumpAndSettle();
      expect(selection.selectedProvider, 'dropbox');
      expect(selection.allowsProvider('google_drive'), false);
      expect(connections.values.length, 2);
      await tester.tap(card('firebase'));
      await tester.pumpAndSettle();
      expect(selection.allowsCurrentAccount, true);
      expect(selection.allowsProvider('dropbox'), false);
    },
  );

  testWidgets(
    'card opens dialog before launching consent and cancellation stays available',
    (tester) async {
      await mount(tester);
      await tester.pumpAndSettle();
      await tester.tap(card('google_drive'));
      await tester.pumpAndSettle();
      expect(connections.calls, kIsWeb ? ['prepare:google_drive'] : isEmpty);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Google Drive'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(connections.calls, [
        'prepare:google_drive',
        'authorize:google_drive',
      ]);
      connections.busy = true;
      connections.notifyListeners();
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('storage-connection-info')),
            )
            .onPressed,
        isNull,
      );
      connections.busy = false;
      connections.notifyListeners();
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(connections.calls.last, 'cancel:google_drive');
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('Dropbox opens authorization on the first Connect click', (
    tester,
  ) async {
    connections.authorizeCompletes = true;
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.ensureVisible(card('dropbox'));
    await tester.tap(card('dropbox'));
    await tester.pumpAndSettle();
    expect(connections.calls, kIsWeb ? ['prepare:dropbox'] : isEmpty);
    expect(find.text('Continue in browser'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(connections.calls, ['prepare:dropbox', 'authorize:dropbox']);
    expect(selection.selectedProvider, 'dropbox');
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'failed initial consent leaves an unconnected card, without a built-in menu',
    (tester) async {
      connections.failures['dropbox'] = SyncProviderFailureKind.unavailable;
      await mount(tester);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: card('firebase'),
          matching: find.byType(PopupMenuButton<String>),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: card('dropbox'),
          matching: find.text('Not connected · Free'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card('dropbox'),
          matching: find.textContaining('Needs attention'),
        ),
        findsNothing,
      );
      expect(connections.values.containsKey('dropbox'), false);
      // Existing connections must still surface operational errors.
      connections.values['dropbox'] = _connection('dropbox');
      connections.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: card('dropbox'),
          matching: find.textContaining('Needs attention'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('browser prepares a fresh Dropbox flow after a popup failure', (
    tester,
  ) async {
    connections.failAuthorization = true;
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.ensureVisible(card('dropbox'));
    await tester.tap(card('dropbox'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(connections.calls, [
      'prepare:dropbox',
      'authorize:dropbox',
      'prepare:dropbox',
    ]);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(
          lookupAppLocalizations(const Locale('en'))
              .externalSyncFailure('reconnectRequired'),
        ),
      ),
      findsOneWidget,
    );
    connections.failAuthorization = false;
    connections.authorizeCompletes = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(connections.calls.last, 'authorize:dropbox');
    expect(selection.selectedProvider, 'dropbox');
    expect(find.byType(AlertDialog), findsNothing);
  }, skip: !kIsWeb);

  testWidgets('Google Drive offers direct consent on this platform', (
    tester,
  ) async {
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(card('google_drive'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(connections.calls, [
      'prepare:google_drive',
      'authorize:google_drive',
    ]);
  });

  testWidgets('legacy grants offer direct authorization', (tester) async {
    connections.values['google_drive'] = _connection('google_drive');
    (service.session!.scheduler as _Scheduler).progress['google_drive:1'] =
        const SyncConnectionProgress(
          failure: SyncProviderFailureKind.sharedSetupRequired,
        );
    await mount(tester);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: card('google_drive'),
        matching: find.text('Sign in to Google Drive on this device.'),
      ),
      findsOneWidget,
    );
    await tester.tap(card('google_drive'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Google Drive'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Sign in to Google Drive on this device.'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('storage-connection-info')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Sign in to the connected Google Drive account on this device. Your notes stay encrypted.',
      ),
      findsOneWidget,
    );
    expect(selection.selectedProvider, 'firebase');
    expect(connections.calls, kIsWeb ? ['prepare:google_drive'] : isEmpty);
  });

  testWidgets(
    'successful consent closes the dialog and selects only the new provider',
    (tester) async {
      connections.authorizeCompletes = true;
      await mount(tester);
      await tester.pumpAndSettle();
      await tester.tap(card('google_drive'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(selection.selectedProvider, 'google_drive');
      expect(selection.allowsCurrentAccount, false);
      expect(selection.allowsProvider('dropbox'), false);
      await tester.tap(
        find.descendant(
          of: card('firebase'),
          matching: find.byType(Radio<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(selection.selectedProvider, 'firebase');
      expect(selection.allowsProvider('google_drive'), false);
    },
  );

  for (final provider in ['google_drive', 'nextcloud']) {
    testWidgets('$provider never returns to Connect while success dismisses', (
      tester,
    ) async {
      connections.authorizeCompletes = true;
      selectionGate = Completer<void>();
      await mount(tester);
      await tester.pumpAndSettle();
      await tester.ensureVisible(card(provider));
      await tester.tap(card(provider));
      await tester.pumpAndSettle();
      if (provider == 'nextcloud') {
        await tester.tap(find.text('Use an app password'));
        await tester.pumpAndSettle();
        final fields = find.byType(TextFormField);
        await tester.enterText(fields.at(0), 'https://cloud.example.com');
        await tester.enterText(fields.at(1), 'alex');
        await tester.enterText(fields.at(2), 'test-app-password');
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pump();
      // Inspect the outgoing route before its animation finishes. A settled
      // frame alone misses the idle-button flash reported after consent.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.widgetWithText(FilledButton, 'Connect'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsNothing);
      expect(selection.selectedProvider, 'firebase');
      selectionGate!.complete();
      await tester.pumpAndSettle();
      expect(selection.selectedProvider, provider);
    });
  }

  testWidgets('cancellation reports when authorization already completed', (
    tester,
  ) async {
    connections.cancelled = false;
    await mount(tester);
    await tester.pumpAndSettle();
    await tester.tap(card('google_drive'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Authorization finished before cancellation.'),
      findsOneWidget,
    );
    expect(selection.selectedProvider, 'firebase');
  });

  testWidgets('disconnect is in the menu and requires confirmation', (
    tester,
  ) async {
    connections.values['dropbox'] = _connection('dropbox');
    await mount(tester);
    await tester.pumpAndSettle();
    await menu(tester, 'dropbox', 'Disconnect');
    expect(find.text('Disconnect Dropbox?'), findsOneWidget);
    expect(connections.calls, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(connections.calls, ['disconnect:dropbox']);
    expect(
      find.textContaining('Access revocation could not be confirmed'),
      findsOneWidget,
    );
  });

  testWidgets(
    'key mismatch hides reconnect and offers recovery through the menu',
    (tester) async {
      connections.values['dropbox'] = _connection('dropbox');
      connections.recovery.add('dropbox');
      await mount(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storage-menu-dropbox')));
      await tester.pumpAndSettle();
      expect(find.text('Reconnect'), findsNothing);
      expect(find.text('Account and encryption'), findsOneWidget);
    },
  );

  testWidgets(
    'Nextcloud browser login uses a separate gesture and retains the grant for setup retry',
    (tester) async {
      var launches = 0, polls = 0;
      connections.failNextcloud = true;
      connections.loginFactory = (server) => NextcloudLoginFlow(
        server: server,
        isCurrent: () => true,
        launch: (_) async {
          launches++;
          return true;
        },
        client: MockClient((request) async {
          if (request.url.path.endsWith('/index.php/login/v2')) {
            return http.Response(
              jsonEncode({
                'poll': {
                  'token': 'private-poll',
                  'endpoint': '$server/login/v2/poll',
                },
                'login': '$server/login/v2/flow/private-browser',
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/poll')) {
            polls++;
            return http.Response(
              jsonEncode({
                'server': '$server',
                'loginName': 'alice',
                'appPassword': 'browser-password',
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'ocs': {
                'meta': {'statuscode': 200},
                'data': {'id': 'alice'},
              },
            }),
            200,
          );
        }),
      );
      await mount(tester);
      await tester.ensureVisible(card('nextcloud'));
      await tester.pumpAndSettle();
      await tester.tap(card('nextcloud'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'https://cloud.example',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Sign In'));
      await tester.pumpAndSettle();
      expect(launches, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('browser-password'), findsNothing);
      connections.failNextcloud = false;
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(connections.nextcloud!.password, 'browser-password');
      expect(connections.nextcloud!.davUserId, 'alice');
      expect(launches, 1);
      expect(polls, 1);
    },
  );

  testWidgets(
    'Nextcloud validates HTTPS and keeps the app password out of the settings display',
    (tester) async {
      await mount(tester);
      await tester.ensureVisible(card('nextcloud'));
      await tester.pumpAndSettle();
      await tester.tap(card('nextcloud'));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.tap(find.text('Use an app password'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), 'http://cloud.example.com');
      await tester.enterText(fields.at(1), 'alex');
      await tester.enterText(fields.at(2), 'private-app-password');
      final secretField = tester.widget<TextField>(
        find.descendant(of: fields.at(2), matching: find.byType(TextField)),
      );
      expect(secretField.obscureText, isTrue);
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(connections.nextcloud, isNull);
      expect(find.textContaining('Enter an HTTPS server URL'), findsOneWidget);
      await tester.enterText(
        fields.at(0),
        'https://cloud.example.com/nextcloud',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(
        connections.nextcloud!.server.toString(),
        'https://cloud.example.com/nextcloud',
      );
      expect(connections.nextcloud!.username, 'alex');
      expect(connections.nextcloud!.password, 'private-app-password');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('private-app-password'), findsNothing);
    },
  );

  for (final provider in ['webdav', 'nextcloud']) {
    testWidgets(
      '$provider keeps instructions behind info and fits a narrow keyboard viewport',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await mount(
          tester,
          textScale: 1.3,
          viewInsets: const EdgeInsets.only(bottom: 280),
        );
        await tester.scrollUntilVisible(card(provider), 200);
        await tester.ensureVisible(card(provider));
        await tester.pumpAndSettle();
        await tester.tap(card(provider));
        await tester.pumpAndSettle();
        expect(find.textContaining('cross-origin'), findsNothing);
        expect(
          find.byType(TextFormField),
          provider == 'webdav' ? findsNWidgets(3) : findsOneWidget,
        );
        final cancel = find.widgetWithText(TextButton, 'Cancel');
        final primary = find.byType(FilledButton).last;
        expect(
          tester.getCenter(cancel).dy,
          closeTo(tester.getCenter(primary).dy, 1),
        );
        expect(tester.getRect(primary).bottom, lessThanOrEqualTo(500));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('storage-connection-info')));
        await tester.pumpAndSettle();
        expect(find.textContaining('cross-origin'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Close'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.byType(TextFormField),
          provider == 'webdav' ? findsNWidgets(3) : findsOneWidget,
        );
      },
    );
  }

  testWidgets('WebDAV uses the manual form and selects only after connecting', (
    tester,
  ) async {
    await mount(tester);
    await tester.scrollUntilVisible(card('webdav'), 180);
    await tester.ensureVisible(card('webdav'));
    await tester.pumpAndSettle();
    await tester.tap(card('webdav'));
    await tester.pumpAndSettle();
    expect(find.text('Open browser'), findsNothing);
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'http://dav.example.test/folder');
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), 'private-app-password');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(connections.webdav, isNull);
    await tester.enterText(fields.at(0), 'https://dav.example.test/folder');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(connections.webdav!.server.path, '/folder');
    expect(connections.webdav!.password, 'private-app-password');
    expect(find.byType(AlertDialog), findsNothing);
    expect(selection.selectedProvider, 'webdav');
  });

  testWidgets(
    'unavailable account offers recovery and does not show connection controls',
    (tester) async {
      service.session = null;
      await mount(tester);
      expect(
        find.text(
          'Sign in and approve or recover this device to connect storage.',
        ),
        findsOneWidget,
      );
      expect(find.text('Connect'), findsNothing);
      expect(find.text('Account and encryption'), findsOneWidget);
    },
  );
}

StorageConnection _connection(
  String provider, {
  bool enabled = true,
  String state = 'ready',
}) => StorageConnection(
  provider: provider,
  libraryId: 'library',
  accountLabel: '$provider account',
  encryptedCapability: 'encrypted',
  generation: 1,
  enabled: enabled,
  state: state,
);

class _Service extends ChangeNotifier implements ExternalSyncService {
  _Service(this.session);
  @override
  LibrarySyncSession? session;
  @override
  bool get initializing => false;
  @override
  SyncProviderFailureKind? get failure => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends ChangeNotifier implements LibrarySyncSession {
  _Session(this.connections);
  @override
  final StorageConnectionController connections;
  @override
  final SyncScheduler scheduler = _Scheduler();
  @override
  final SyncStatusStore status = _History();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connections extends ChangeNotifier
    implements StorageConnectionController {
  final values = <String, StorageConnection>{};
  final states = <String, StorageConnectionAction>{};
  final recovery = <String>{};
  final calls = <String>[];
  StorageDavAccess? nextcloud, webdav;
  bool cancelled = true;
  bool busy = false;
  bool authorizeCompletes = false;
  bool failAuthorization = false;
  final failures = <String, SyncProviderFailureKind>{};
  bool failNextcloud = false;
  NextcloudLoginFlow Function(Uri)? loginFactory;
  @override
  NextcloudLoginFlow createNextcloudLogin(Uri server) => loginFactory!(server);
  @override
  Map<String, StorageConnection> get connections => values;
  @override
  Map<String, StorageConnectionAction> get actions => states;
  @override
  Map<String, SyncProviderFailureKind> get errors => failures;
  @override
  SyncProviderFailureKind? get metadataFailure => null;
  @override
  bool isBusy(String provider) => busy;
  @override
  bool canCancelOAuth(String provider) => states.containsKey(provider);
  @override
  Future<bool> cancelOAuth(String provider) async {
    calls.add('cancel:$provider');
    states.remove(provider);
    notifyListeners();
    return cancelled;
  }

  @override
  bool isLocallyStopped(String provider) => false;
  @override
  bool needsKeyRecovery(String provider) => recovery.contains(provider);
  @override
  Future<void> setEnabled(String provider, bool enabled) async {
    calls.add('$provider:$enabled');
    values[provider] = _connection(provider, enabled: enabled);
    notifyListeners();
  }

  StorageUsage? usage;
  @override
  Future<StorageUsage?> readStorageUsage(String provider) async => usage;

  @override
  Future<Map<String, dynamic>> requestClearOtp(String provider) async {
    calls.add('clear-code:$provider');
    return {'requestId': 'request'};
  }

  @override
  Future<void> clearSyncedData(
    String provider,
    String requestId,
    String code,
    Future<void> Function() drain,
  ) async {
    expect(requestId, 'request');
    expect(code, '123456');
    calls.add('clear:$provider');
  }

  @override
  Future<bool> disconnect(String provider) async {
    calls.add('disconnect:$provider');
    values.remove(provider);
    notifyListeners();
    return false;
  }

  @override
  Future<void> prepareOAuth(String provider) async {
    calls.add('prepare:$provider');
    failures.remove(provider);
    states[provider] = StorageConnectionAction.awaitingConsent;
    notifyListeners();
  }

  @override
  Future<void> authorizeOAuth(String provider) async {
    calls.add('authorize:$provider');
    if (failAuthorization) {
      failures[provider] = SyncProviderFailureKind.reconnectRequired;
      notifyListeners();
      throw const SyncProviderFailure(
        SyncProviderFailureKind.reconnectRequired,
      );
    }
    if (authorizeCompletes) {
      states.remove(provider);
      values[provider] = _connection(provider);
      notifyListeners();
    }
  }

  @override
  Future<void> connectWebDav(StorageDavAccess access) async {
    webdav = access;
    values['webdav'] = _connection('webdav');
    notifyListeners();
  }

  @override
  Future<void> connectNextcloud(StorageDavAccess access) async {
    if (failNextcloud) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    }
    nextcloud = access;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Scheduler extends ChangeNotifier implements SyncScheduler {
  @override
  final Map<String, SyncConnectionProgress> progress = {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History implements SyncStatusStore {
  @override
  Map<String, DateTime> get lastSuccess => {
    'google_drive:1': DateTime.utc(2026, 10, 20, 12),
  };
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
