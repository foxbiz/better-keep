import 'dart:async';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/reminder_action_receipt_service.dart';
import 'package:better_keep/services/reminder_action_ui_channel_native.dart'
    as action_ui;
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:better_keep/services/reminder_session_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database database;
  final coordinator = ReminderCoordinator.instance;
  const noteId = 73;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ReminderSessionService.resetCacheForTesting();
    await ReminderSessionService.setSignedIn(true);
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(database);
    await ReminderActionReceiptService.createTable(database);
    AppState.db = database;
    coordinator.detachUiActionListener();
  });

  tearDown(() async {
    coordinator.detachUiActionListener();
    await database.close();
  });

  Future<void> insertCompletedNoteAndReceipt() async {
    final note = Note(
      id: noteId,
      title: 'Completed from notification',
      content: '',
      completed: true,
    );
    await database.insert(Note.model, note.toJson());
    await ReminderActionReceiptService.claim(
      database,
      'note:$noteId:revision:1',
      noteId: noteId,
      action: 'mark_done',
    );
  }

  test('native action signal wakes the main isolate immediately', () async {
    await insertCompletedNoteAndReceipt();
    final updated = Completer<Note>();
    void listener(NoteEvent event) {
      if (!updated.isCompleted) updated.complete(event.note);
    }

    Note.on('updated', listener);
    addTearDown(() => Note.off('updated', listener));
    coordinator.attachUiActionListener();

    expect(action_ui.signalReminderActionUi(noteId), isTrue);
    final note = await updated.future.timeout(const Duration(seconds: 1));

    expect(note.id, noteId);
    expect(note.completed, isTrue);
    expect(
      await ReminderActionReceiptService.pendingUiUpdates(database),
      isEmpty,
    );
  });

  test(
    'receipt remains a fallback when no main isolate is listening',
    () async {
      await insertCompletedNoteAndReceipt();
      expect(action_ui.signalReminderActionUi(noteId), isFalse);
      expect(
        await ReminderActionReceiptService.pendingUiUpdates(database),
        hasLength(1),
      );

      final updated = Completer<Note>();
      void listener(NoteEvent event) {
        if (!updated.isCompleted) updated.complete(event.note);
      }

      Note.on('updated', listener);
      addTearDown(() => Note.off('updated', listener));
      await coordinator.consumePendingUiActions();

      expect((await updated.future).completed, isTrue);
      expect(
        await ReminderActionReceiptService.pendingUiUpdates(database),
        isEmpty,
      );
    },
  );

  test('duplicate wake-ups consume one receipt once', () async {
    await insertCompletedNoteAndReceipt();
    var updateCount = 0;
    final updated = Completer<void>();
    void listener(NoteEvent event) {
      updateCount++;
      if (!updated.isCompleted) updated.complete();
    }

    Note.on('updated', listener);
    addTearDown(() => Note.off('updated', listener));
    coordinator.attachUiActionListener();

    action_ui.signalReminderActionUi(noteId);
    action_ui.signalReminderActionUi(noteId);
    await updated.future.timeout(const Duration(seconds: 1));
    await pumpEventQueue();

    expect(updateCount, 1);
    expect(
      await ReminderActionReceiptService.pendingUiUpdates(database),
      isEmpty,
    );
  });
}
