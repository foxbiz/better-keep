import 'dart:convert';
import 'dart:io';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/services/ios_image_share_inbox.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/shared_image_note_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database db;
  late _Importer importer;
  late List<Map<String, dynamic>> pending;
  final completed = <String>[];
  var failAcknowledgement = false;
  final attempts = <String, int>{};
  final failures = <Object>[];
  const id = 'C1D3C7DB-9F89-4EBD-BFC7-32FDE2A00B00';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Note.createTable(db);
    await NoteSyncTrack.createTable(db);
    AppState.db = db;
    importer = _Importer();
    completed.clear();
    attempts.clear();
    failures.clear();
    failAcknowledgement = false;
    pending = [
      {
        'id': id,
        'paths': ['/inbox/one.png', '/inbox/two.png'],
      },
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosImageShareInbox.channel, (call) async {
          if (call.method == 'pending') {
            return pending
                .where((batch) => (attempts[batch['id']] ?? 0) < 3)
                .toList();
          }
          if (call.method == 'failed') {
            final id = call.arguments as String;
            return attempts[id] = (attempts[id] ?? 0) + 1;
          }
          if (failAcknowledgement) throw PlatformException(code: 'disk_error');
          completed.add(call.arguments as String);
          pending = pending
              .where((batch) => batch['id'] != call.arguments)
              .toList();
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(IosImageShareInbox.channel, null);
    await db.close();
  });

  test('imports an ordered batch and acknowledges only after saving', () async {
    final busy = <bool>[];
    final inbox = IosImageShareInbox(
      importer,
      onImportFailed: failures.add,
      onBusy: busy.add,
    );
    expect(await inbox.importPending(), 1);
    expect(importer.paths, ['/inbox/one.png', '/inbox/two.png']);
    expect((await Note.findBySyncId(id))?.syncId, id);
    expect(completed, [id]);
    expect(await inbox.importPending(), 0);
    expect(importer.calls, 1);
    expect(busy, [
      true,
      false,
    ], reason: 'Empty resume checks must not flash a loading overlay');
  });

  test('an acknowledgement retry does not create another note', () async {
    final opened = <Note>[];
    final inbox = IosImageShareInbox(
      importer,
      onImportFailed: failures.add,
      onImported: opened.add,
    );
    failAcknowledgement = true;
    expect(await inbox.importPending(), 1);
    expect(attempts, isEmpty);
    expect(failures, isEmpty);
    failAcknowledgement = false;
    expect(await inbox.importPending(), 0);
    expect(importer.calls, 1);
    expect(completed, [id]);
    expect(await db.query('note'), hasLength(1));
    expect(opened, hasLength(1));
    expect(opened.single.syncId, id);
  });

  test('a backlog opens only the newest successfully imported note', () async {
    const nextId = 'C1D3C7DB-9F89-4EBD-BFC7-32FDE2A00B01';
    pending.add({
      'id': nextId,
      'paths': ['/inbox/last.png'],
    });
    final opened = <Note>[];
    final inbox = IosImageShareInbox(importer, onImported: opened.add);
    expect(await inbox.importPending(), 2);
    expect(opened.map((note) => note.syncId), [nextId]);
    expect(await inbox.importPending(), 0);
    expect(opened, hasLength(1));
  });

  test('failed imports remain available to retry', () async {
    importer.fail = true;
    final busy = <bool>[];
    final inbox = IosImageShareInbox(
      importer,
      onImportFailed: failures.add,
      onBusy: busy.add,
    );
    expect(await inbox.importPending(), 0);
    expect(failures, hasLength(1));
    expect(completed, isEmpty);
    expect(pending, hasLength(1));
    expect(await db.query('note'), isEmpty);
    expect(busy, [true, false], reason: 'Import failure must dismiss progress');
    importer.fail = false;
    expect(await inbox.importPending(), 1);
    expect(completed, [id]);
  });

  test('three permanent failures quarantine a batch and notify only on its first failure', () async {
    importer.fail = true;
    for (var i = 0; i < 5; i++) {
      // New instances simulate relaunches; retry counts survive them natively.
      await IosImageShareInbox(
        importer,
        onImportFailed: failures.add,
      ).importPending();
    }
    expect(importer.calls, 3);
    expect(attempts[id], 3);
    expect(failures, hasLength(1));
    expect(completed, isEmpty);
  });

  for (final error in <Object>[
    const SharedImageImportException(
      '/inbox/one.png',
      FileSystemException('Locked'),
    ),
    const CloudOperationCancelled(),
    PlatformException(code: 'temporarily_unavailable'),
    StateError('Failed to save shared image note'),
  ]) {
    test(
      'transient ${error.runtimeType} remains retryable after three failures',
      () async {
        importer.fail = true;
        importer.failure = error;
        final inbox = IosImageShareInbox(
          importer,
          onImportFailed: failures.add,
        );
        for (var attempt = 0; attempt < 4; attempt++) {
          expect(await inbox.importPending(), 0);
        }
        expect(attempts, isEmpty);
        expect(failures, hasLength(1));
        expect(pending, hasLength(1));
        expect(completed, isEmpty);
        importer.fail = false;
        expect(await inbox.importPending(), 1);
        expect(completed, [id]);
      },
    );
  }

  test('a failed batch does not block later valid shares', () async {
    const nextId = 'C1D3C7DB-9F89-4EBD-BFC7-32FDE2A00B01';
    importer.failIds.add(id);
    pending.add({
      'id': nextId,
      'paths': ['/inbox/valid.png'],
    });
    expect(
      await IosImageShareInbox(
        importer,
        onImportFailed: failures.add,
      ).importPending(),
      1,
    );
    expect(completed, [nextId]);
    expect(pending.single['id'], id);
    expect(await Note.findBySyncId(nextId), isNotNull);
  });
}

class _Importer extends SharedImageNoteService {
  var calls = 0;
  var fail = false;
  Object failure = const SharedImageImportException(
    '/inbox/one.png',
    FormatException('Invalid image'),
  );
  final failIds = <String>{};
  List<String> paths = [];

  @override
  Future<Note> create(List<SharedMediaFile> images, {String? shareId}) async {
    calls++;
    if (fail || failIds.contains(shareId)) {
      throw failure;
    }
    paths = images.map((image) => image.path).toList();
    final note = Note(
      // This stub skips image I/O, so saves can occur in the same millisecond.
      id: calls,
      title: 'Shared images',
      syncId: shareId,
      content: jsonEncode([
        {'insert': 'Images\n'},
      ]),
    );
    expect(await note.save(false), greaterThan(0));
    return note;
  }
}
