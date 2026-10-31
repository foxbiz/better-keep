import 'dart:async';

import 'package:better_keep/dialogs/labels.dart' as dialog;
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/pages/home/labels.dart' as home;
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  for (final inDialog in [false, true]) {
    final location = inDialog ? 'dialog' : 'tabs';

    Future<void> mount(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: inDialog
              ? const dialog.Labels()
              : home.Labels(onSelect: (_) {}),
        ),
      ),
    );

    testWidgets('$location reconcile same-name replicas after sync', (
      tester,
    ) async {
      final database = _LabelDatabase()
        ..rows = [_row(1, 'Work'), _row(2, 'Home')];
      AppState.db = database;
      await mount(tester);
      await tester.pumpAndSettle();

      // Another device's label has a different identity but the same name.
      database.rows.add(_row(3, 'Work'));
      _notify(database.rows.last, 'created');
      _notify(database.rows.last, 'created');
      await tester.pumpAndSettle();
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);

      // Rename a previously hidden replica, then merge its display name again.
      database.rows[2] = _row(3, 'Travel');
      _notify(database.rows[2], 'updated');
      await tester.pumpAndSettle();
      expect(find.text('Travel'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      database.rows[2] = _row(3, 'Work');
      _notify(database.rows[2], 'updated');
      await tester.pumpAndSettle();
      expect(find.text('Travel'), findsNothing);
      expect(find.text('Work'), findsOneWidget);

      // Deleting the displayed representative must reveal the remaining one.
      final deleted = database.rows.removeAt(0);
      _notify(deleted, 'deleted');
      await tester.pumpAndSettle();
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      expect(database.rows, hasLength(2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$location ignore an older load completing after sync', (
      tester,
    ) async {
      final initialLoad = Completer<List<Map<String, Object?>>>();
      final database = _LabelDatabase()..nextQuery = initialLoad.future;
      AppState.db = database;
      await mount(tester);
      database.rows = [_row(1, 'Current')];
      _notify(database.rows.single, 'created');
      await tester.pumpAndSettle();
      expect(find.text('Current'), findsOneWidget);
      initialLoad.complete([_row(1, 'Old')]);
      await tester.pumpAndSettle();
      expect(find.text('Current'), findsOneWidget);
      expect(find.text('Old'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Map<String, Object?> _row(int id, String name) => {
  'id': id,
  'sync_id': 'replica-$id',
  'name': name,
  'is_system': 0,
};

void _notify(Map<String, Object?> row, String event) {
  Label.fromJson(row).notifyWithOrigin(event, ModelChangeOrigin.remoteSync);
}

class _LabelDatabase implements Database {
  List<Map<String, Object?>> rows = [];
  Future<List<Map<String, Object?>>>? nextQuery;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    expect(table, Label.model);
    final pending = nextQuery;
    nextQuery = null;
    return pending ??
        rows.map((row) => Map<String, Object?>.from(row)).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
