import 'dart:convert';

import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    Note.pinContentEncryptOverride = null;
    Note.pinContentDecryptOverride = null;
  });

  tearDown(() {
    Note.pinContentEncryptOverride = null;
    Note.pinContentDecryptOverride = null;
  });

  testWidgets('unchanged locked editor re-locks before its route closes', (
    tester,
  ) async {
    const password = '1234';
    final plainContent = _content('secret');
    final note = Note(
      locked: true,
      content: await encrypt(plainContent, password),
    );
    await note.unlock(password);
    AppState.forgetLockedNotePassword = true;

    await _pumpEditorLauncher(tester, note);
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Open editor'), findsOneWidget);
    expect(note.unlocked, isFalse);
    expect(note.password, isNull);
    expect(note.content, isNot(plainContent));

    await note.unlock(password);
    expect(note.content, plainContent);
  });

  testWidgets('disabled setting keeps the cached PIN after closing', (
    tester,
  ) async {
    const password = '1234';
    final plainContent = _content('secret');
    final note = Note(
      locked: true,
      content: await encrypt(plainContent, password),
    );
    await note.unlock(password);
    AppState.forgetLockedNotePassword = false;

    await _pumpEditorLauncher(tester, note);
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Open editor'), findsOneWidget);
    expect(note.unlocked, isTrue);
    expect(note.password, password);
    expect(note.content, plainContent);
  });

  testWidgets('re-lock failure keeps the editor open and preserves the PIN', (
    tester,
  ) async {
    const password = '1234';
    final plainContent = _content('secret');
    final note = Note(
      locked: true,
      content: await encrypt(plainContent, password),
    );
    await note.unlock(password);
    AppState.forgetLockedNotePassword = true;
    Note.pinContentEncryptOverride = (_, _) async {
      throw StateError('injected encryption failure');
    };

    await _pumpEditorLauncher(tester, note);
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditor), findsOneWidget);
    expect(note.unlocked, isTrue);
    expect(note.password, password);
    expect(note.content, plainContent);
  });

  testWidgets('final save failure keeps the editor open before re-locking', (
    tester,
  ) async {
    const password = '1234';
    final plainContent = _content('secret');
    final note = Note(
      locked: true,
      content: await encrypt(plainContent, password),
    );
    await note.unlock(password);
    AppState.forgetLockedNotePassword = true;
    Note.pinContentEncryptOverride = (_, _) async {
      throw StateError('injected serialization failure');
    };

    await _pumpEditorLauncher(tester, note);
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Changed');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.byType(NoteEditor), findsOneWidget);
    expect(note.unlocked, isTrue);
    expect(note.password, password);
    expect(note.content, contains('Changed'));
  });
}

Future<void> _pumpEditorLauncher(WidgetTester tester, Note note) {
  return tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => NoteEditor(note: note)),
              );
            },
            child: const Text('Open editor'),
          ),
        ),
      ),
    ),
  );
}

String _content(String text) => jsonEncode([
  {'insert': '$text\n'},
]);
