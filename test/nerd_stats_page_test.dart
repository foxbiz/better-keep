import 'dart:async';

import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/pages/settings/nerd_stats_page.dart';
import 'package:better_keep/services/firebase_sync_preference.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  testWidgets('diagnostics follow the selected provider after opening', (
    tester,
  ) async {
    final updates = StreamController<FirebaseSyncSelection>();
    final previous = FirebaseSyncPreference.instanceOverride;
    final preference = FirebaseSyncPreference(
      currentUid: () => 'qa',
      watch: (_) => updates.stream,
      write: (_, _) async => throw UnsupportedError('Read only'),
    )..bind('qa');
    FirebaseSyncPreference.instanceOverride = preference;
    addTearDown(() async {
      FirebaseSyncPreference.instanceOverride = previous;
      preference.dispose();
      await updates.close();
    });
    final database = (await tester.runAsync(
      () => databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
    ))!;
    AppState.db = database;
    addTearDown(database.close);
    await tester.runAsync(() => NoteSyncTrack.createTable(database));
    await tester.pumpWidget(_app(const NerdStatsPage()));
    const providers = {
      'firebase': 'Better Keep cloud',
      'dropbox': 'Dropbox',
      'none': 'Sync off',
    };
    var revision = 0;
    for (final provider in providers.keys) {
      updates.add(
        FirebaseSyncSelection(
          provider == 'firebase',
          provider: provider,
          confirmed: true,
          revision: ++revision,
        ),
      );
      await tester.pump();
      final title = find.text(providers[provider]!);
      for (
        var attempt = 0;
        title.evaluate().isEmpty && attempt < 10;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 300));
        await _drainDatabaseWork(tester);
      }
      expect(
        title,
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join(', '),
      );
      expect(
        find.text('Pending Notes'),
        provider == 'firebase' ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('Unacknowledged Notes'),
        provider == 'dropbox' ? findsOneWidget : findsNothing,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _drainDatabaseWork(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 250)),
  );
  await tester.pump();
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: home,
);
