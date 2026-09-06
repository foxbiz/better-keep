import 'dart:async';

import 'package:better_keep/dialogs/labels.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/state.dart';
import 'package:firebase_core/firebase_core.dart';
// Use Firebase's installed host mock to keep label sync signed out and offline.
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late _SaveDatabase saves;

  setUpAll(() async {
    sqfliteFfiInit();
    TestFirebaseCoreHostApi.setUp(_FirebaseHost());
    await Firebase.initializeApp();
    FirebaseBackend.configureLive();
  });
  tearDownAll(FirebaseBackend.resetForTesting);
  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Label.createTable(database);
    saves = _SaveDatabase(database);
    AppState.db = saves;
    await Label(name: 'Existing').save(sync: false);
    saves.attempts = 0;
  });
  tearDown(() async {
    await database.close();
  });

  for (final mode in [Labels.labelsModeSelect, Labels.labelsModeManage]) {
    final selecting = mode == Labels.labelsModeSelect;
    final location = selecting ? 'note editor' : 'sidebar';
    final confirmation = selecting
        ? 'Create “Work” and add it to this note?'
        : 'Create “Work”?';

    testWidgets('$location: OK confirms and waits for a single save', (
      tester,
    ) async {
      const initial = ['Existing'];
      final result = await _open(tester, mode, initial: initial);
      await tester.enterText(find.byType(TextField), '  Work  ');
      final submit = tester.widget<TextButton>(_button('OK')).onPressed!;
      submit();
      submit();
      await _waitFor(
        tester,
        () => find.text(confirmation).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(saves.attempts, 0);

      final release = Completer<void>();
      saves.delay = release.future;
      final confirm = tester
          .widget<TextButton>(_button('Add label'))
          .onPressed!;
      confirm();
      confirm();
      await _waitFor(tester, () => saves.attempts == 1);
      await tester.pumpAndSettle();
      expect(result.closed, isFalse);
      expect(_input(tester), '  Work  ');
      expect(tester.widget<TextButton>(_button('OK')).onPressed, isNull);
      expect(tester.widget<TextButton>(_button('Cancel')).onPressed, isNull);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
            .onPressed,
        isNull,
      );
      submit();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.tapAt(const Offset(5, 5));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(result.closed, isFalse);
      expect(saves.attempts, 1);

      release.complete();
      await _waitFor(tester, () => result.closed);
      await tester.pumpAndSettle();
      expect(result.selection, selecting ? ['Existing', 'Work'] : null);
      expect(initial, ['Existing']);
      expect(await tester.runAsync(() => _names(database)), [
        'Existing',
        'Work',
      ]);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
      '$location: confirmation Cancel retains input; main Cancel discards draft',
      (tester) async {
        final initial = <String>[];
        final result = await _open(tester, mode, initial: initial);
        if (selecting) {
          await tester.tap(find.widgetWithText(ListTile, 'Existing'));
        }
        await tester.enterText(find.byType(TextField), '  Work  ');
        await tester.tap(_button('OK'));
        await _waitFor(
          tester,
          () => find.text(confirmation).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await tester.tap(_button('Cancel').last);
        await tester.pumpAndSettle();
        expect(result.closed, isFalse);
        expect(_input(tester), '  Work  ');
        expect(saves.attempts, 0);
        expect(initial, isEmpty);
        await tester.tap(_button('Cancel'));
        await tester.pumpAndSettle();
        expect(result.closed, isTrue);
        expect(result.selection, isNull);
        expect(await tester.runAsync(() => _names(database)), ['Existing']);
      },
    );

    testWidgets(
      '$location: plus and Enter add immediately and Cancel keeps created labels',
      (tester) async {
        final result = await _open(tester, mode, initial: const []);
        await tester.enterText(find.byType(TextField), '  Work  ');
        await tester.tap(find.byIcon(Icons.add));
        await _waitFor(tester, () => _input(tester).isEmpty);
        expect(result.closed, isFalse);
        expect(find.text(confirmation), findsNothing);
        if (selecting) expect(find.byIcon(Icons.check), findsOneWidget);

        await tester.enterText(find.byType(TextField), ' Работа ');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _waitFor(tester, () => _input(tester).isEmpty);
        expect(result.closed, isFalse);
        if (selecting) expect(find.byIcon(Icons.check), findsNWidgets(2));
        expect(saves.attempts, 2);
        await tester.tap(_button('Cancel'));
        await tester.pumpAndSettle();
        expect(result.selection, isNull);
        expect(result.closed, isTrue);
        expect(await tester.runAsync(() => _names(database)), [
          'Existing',
          'Work',
          'Работа',
        ]);
      },
    );

    testWidgets(
      '$location: existing names need no confirmation and are not duplicated',
      (tester) async {
        await tester.runAsync(() => Label(name: 'Work').save(sync: false));
        saves.attempts = 0;
        final result = await _open(tester, mode, initial: const ['Existing']);
        await tester.enterText(find.byType(TextField), ' Work ');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _waitFor(tester, () => _input(tester).isEmpty);
        await tester.enterText(find.byType(TextField), ' Work ');
        await tester.tap(_button('OK'));
        await _waitFor(tester, () => result.closed);
        await tester.pumpAndSettle();
        expect(find.text(confirmation), findsNothing);
        expect(saves.attempts, 0);
        expect(result.selection, selecting ? ['Existing', 'Work'] : null);
        expect(await tester.runAsync(() => _names(database)), [
          'Existing',
          'Work',
        ]);
      },
    );

    testWidgets(
      '$location: empty and whitespace OK retain selection behavior',
      (tester) async {
        for (final input in ['', '   ']) {
          final result = await _open(tester, mode, initial: const []);
          if (selecting) {
            await tester.tap(find.widgetWithText(ListTile, 'Existing'));
          }
          await tester.enterText(find.byType(TextField), input);
          await tester.tap(_button('OK'));
          await tester.pumpAndSettle();
          expect(result.closed, isTrue);
          expect(result.selection, selecting ? ['Existing'] : null);
          expect(saves.attempts, 0);
        }
        final unchanged = await _open(
          tester,
          mode,
          initial: const ['Existing'],
        );
        await tester.tap(_button('OK'));
        await tester.pumpAndSettle();
        expect(unchanged.closed, isTrue);
        expect(unchanged.selection, isNull);
      },
    );

    testWidgets(
      '$location: failed save retains text and selection until retry succeeds',
      (tester) async {
        final result = await _open(tester, mode, initial: const ['Existing']);
        saves.fail = true;
        await tester.enterText(find.byType(TextField), '  Work  ');
        await tester.tap(_button('OK'));
        await _waitFor(
          tester,
          () => find.text(confirmation).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await tester.tap(_button('Add label'));
        await _waitFor(
          tester,
          () => find
              .text('Couldn’t save label. Try again.')
              .evaluate()
              .isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(result.closed, isFalse);
        expect(_input(tester), '  Work  ');
        expect(await tester.runAsync(() => _names(database)), ['Existing']);
        if (selecting) expect(find.byIcon(Icons.check), findsOneWidget);
        expect(
          tester.widget<TextButton>(_button('Cancel')).onPressed,
          isNotNull,
        );

        saves.fail = false;
        await tester.tap(find.byIcon(Icons.add));
        await _waitFor(tester, () => _input(tester).isEmpty);
        expect(find.text('Couldn’t save label. Try again.'), findsNothing);
        expect(result.closed, isFalse);
        await tester.tap(_button('OK'));
        await tester.pumpAndSettle();
        expect(result.selection, selecting ? ['Existing', 'Work'] : null);
        expect(saves.attempts, 2);
        expect(await tester.runAsync(() => _names(database)), [
          'Existing',
          'Work',
        ]);
      },
    );
  }

  testWidgets(
    'confirmation reuses a label created while open and matches exact case',
    (tester) async {
      await tester.runAsync(() => Label(name: 'work').save(sync: false));
      final result = await _open(tester, Labels.labelsModeSelect);
      await tester.enterText(find.byType(TextField), 'Work');
      await tester.tap(_button('OK'));
      await _waitFor(tester, () => _button('Add label').evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      await tester.runAsync(() => Label(name: 'Work').save(sync: false));
      saves.attempts = 0;
      await tester.tap(_button('Add label'));
      await _waitFor(tester, () => result.closed);
      await tester.pumpAndSettle();
      expect(result.selection, ['Work']);
      expect(saves.attempts, 0);
      expect(await tester.runAsync(() => _names(database)), [
        'Existing',
        'Work',
        'work',
      ]);
    },
  );
}

Finder _button(String text) => find.widgetWithText(TextButton, text);
String _input(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

Future<List<String>> _names(Database database) async => (await database.query(
  'label',
  orderBy: 'name',
)).map((row) => row['name']! as String).toList();

class _DialogResult {
  bool closed = false;
  List<String>? selection;
}

Future<_DialogResult> _open(
  WidgetTester tester,
  int mode, {
  List<String>? initial,
}) async {
  final result = _DialogResult();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.selection = await labels(
                context,
                mode: mode,
                initiallySelected: initial,
              );
              result.closed = true;
            },
            child: const Text('Open labels'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(_button('Open labels'));
  await _waitFor(tester, () => find.byType(TextField).evaluate().isNotEmpty);
  await tester.pumpAndSettle();
  return result;
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 200 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue, reason: 'Label dialog did not settle');
}

class _FirebaseHost extends MockFirebaseApp {
  @override
  Future<List<CoreInitializeResponse>> initializeCore() async {
    final apps = await super.initializeCore();
    apps.single.options.storageBucket = 'labels-dialog-test.invalid';
    return apps;
  }
}

class _SaveDatabase implements Database {
  _SaveDatabase(this.delegate);
  final Database delegate;
  int attempts = 0;
  Future<void>? delay;
  bool fail = false;

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    attempts++;
    if (delay != null) await delay;
    if (fail) throw StateError('Simulated label save failure');
    return delegate.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

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
  }) => delegate.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) => delegate.rawQuery(sql, arguments);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
