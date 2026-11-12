import 'account_file_cleanup_test.dart' as cleanup;

import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/services/note_sync_batch.dart';
import 'package:better_keep/services/sync_logout_check.dart';
import 'package:better_keep/components/sync_progress_widget.dart';

// Real platform SQLite/files/crypto, synthetic Dropbox HTTP boundary.
// The optional automatic matrix authenticates only with disposable emulators.
// Neither matrix touches a user's library/provider files.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/home/notes.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/services/external_sync/replica_model_notifier.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/label_sync_track.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sync_track.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/sketch_preview_generator.dart';
import 'package:better_keep/services/reminder_coordinator.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:better_keep/services/sketch_strokes_file_service.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/note_sort_service.dart';
import 'package:better_keep/services/external_sync/dropbox_sync_transport.dart';
import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/external_sync_refresh.dart';
import 'package:better_keep/services/external_sync/external_sync_progress.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/external_sync/library_sync_session.dart';
import 'package:better_keep/services/external_sync/library_replica_content.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/storage_connection_controller.dart';
import 'package:better_keep/services/external_sync/sync_attachment_store.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/sync_replica_store.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:better_keep/services/external_sync/sync_status_store.dart';
import 'package:better_keep/services/external_sync/storage_connection.dart';
import 'package:better_keep/services/external_sync/sync_change_signals.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:better_keep/utils/db_init.dart'
    if (dart.library.html) 'package:better_keep/utils/db_init_web.dart'
    if (dart.library.io) 'package:better_keep/utils/db_init_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('SYNC_STRESS')) {
    if (kIsWeb) {
      testWidgets('browser sync skips unsupported reminder library scans', (
        tester,
      ) async {
        var initializations = 0;
        final coordinator = ReminderCoordinator.forTesting(
          initialize: () async {
            initializations++;
            throw StateError('Browser must not initialize reminder scheduling');
          },
        );
        for (var i = 0; i < 1000; i++) {
          coordinator.requestReconciliation();
        }
        await coordinator.waitForRequestedReconciliation();
        await coordinator.reconcileAll();
        expect(initializations, 0);
      });
    }
    testWidgets('1000-note image sync stress and durable retry', (
      tester,
    ) async {
      await _stressMatrix(tester);
    }, timeout: const Timeout(Duration(minutes: 30)));
    return;
  }
  cleanup.registerFileCleanupTest();

  testWidgets(
    'free login restores nine notes and image; unchanged refresh completes',
    (tester) async {
      initializeDb();
      final files = await fileSystem();
      final root = p.join(
        await files.documentDir,
        'sync-restore-qa-${DateTime.now().microsecondsSinceEpoch}',
      );
      final server = _DropboxBoundary();
      final replicas = <_Replica>[];
      addTearDown(() async {
        for (final replica in replicas) {
          await replica.session.close();
          replica.client.close();
          await replica.db.close();
          await deleteDatabase(replica.db.path);
        }
        await _deleteTestFiles(files, root);
      });
      final a = await _Replica.create(files, p.join(root, 'a'), server);
      replicas.add(a);
      final image = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNwWXXmPwAFqgK6oQQFNwAAAABJRU5ErkJggg==',
      );
      final imagePath = p.join(a.root, 'image.png');
      await files.writeBytes(imagePath, image);
      for (var i = 0; i < 9; i++) {
        await a.db.insert('note', {
          'id': i + 1,
          'sync_id': 'restore-note-$i',
          'title': 'QA restore $i',
          'content': jsonEncode([
            {'insert': 'QA content $i\n'},
          ]),
          'created_at': '2030-01-01T00:00:00.000Z',
          'updated_at': '2030-01-01T00:00:01.000Z',
          'attachments': jsonEncode(
            i == 0
                ? [
                    {
                      'id': 'image',
                      'type': 'image',
                      'data': {
                        'src': imagePath,
                        'size': image.length,
                        'index': 0,
                        'aspectRatio': '1:1',
                        'lastModified': '',
                      },
                    },
                  ]
                : [],
          ),
        });
      }
      await a.sync();
      // A small visible library can retain many deletions. Restore must process
      // that history without re-creating notes or downloading obsolete payloads.
      for (var i = 0; i < 100; i++) {
        await a.adapter.publish(
          SyncRevision(
            kind: SyncEntityKind.note,
            entityId: 'removed-$i',
            revisionId: 'deleted-$i',
            modifiedAtMicros: i,
            deleted: true,
            payloadObjectId: null,
          ),
        );
      }
      final writes = server.uploads;
      server.delay = const Duration(milliseconds: 100);
      final clock = Stopwatch()..start();
      final interrupted = Completer<void>();
      final closing = Completer<void>();
      final partial = await _Replica.create(
        files,
        p.join(root, 'b'),
        server,
        restoreOnStart: true,
        onApplied: (change) async {
          if (change.revision.kind == SyncEntityKind.note &&
              !change.revision.deleted &&
              !interrupted.isCompleted) {
            interrupted.complete();
            await closing.future;
          }
        },
      );
      replicas.add(partial);
      final checked = <int>[];
      void observeChecking() {
        final notes = externalSyncProgress(
          connections: partial.session.connections.connections.values,
          progress: partial.session.scheduler.progress,
          transfers: partial.session.transfers,
          automatic: false,
        ).notes;
        if (notes != null && notes.stage == NoteTransferStage.checking) {
          if (notes.done == 0) checked.clear();
          if (checked.isEmpty || checked.last != notes.done) {
            checked.add(notes.done);
          }
        }
      }

      partial.session.addListener(observeChecking);
      try {
        await interrupted.future.timeout(const Duration(seconds: 30));
        expect(checked.last, 109);
        expect(checked, orderedEquals(checked.toSet().toList()..sort()));
        expect(
          checked.any((done) => done > 0 && done < 109),
          isTrue,
          reason: 'Show progress during listing, before downloading',
        );
        expect(await partial.db.query('note'), hasLength(1));
        final progress =
            partial.session.transfers[partial.adapter.connectionId]!;
        expect(progress.stage, NoteTransferStage.downloading);
        expect(
          progress.total,
          9,
          reason: 'Deleted notes have no content to download',
        );
        partial.session.retire();
      } finally {
        partial.session.removeListener(observeChecking);
        closing.complete();
      }
      await partial.session.close(pruneCache: false);
      partial.client.close();
      await partial.db.close();
      replicas.remove(partial);
      final b = await _Replica.create(
        files,
        p.join(root, 'b'),
        server,
        restoreOnStart: true,
        notifyModels: true,
      );
      replicas.add(b);
      final resumedRefresh = await refreshExternalSession(
        b.session,
        isCurrent: () => true,
        progress: () => externalSyncProgress(
          connections: b.session.connections.connections.values,
          progress: b.session.scheduler.progress,
          automatic: false,
        ),
      );
      expect(resumedRefresh, SyncRefreshOutcome.complete);
      expect(await b.db.query('note'), hasLength(9));
      expect(
        server.uploads,
        writes,
        reason: 'Free initial restore is download-only',
      );
      expect(server.maxConcurrentDownloads, 8);
      final row = (await b.db.query(
        'note',
        where: "sync_id = 'restore-note-0'",
      )).single;
      final media = jsonDecode(row['attachments'] as String) as List;
      expect(
        await b.session.attachments.read(media.single['data']['src'] as String),
        image,
      );
      debugPrint(
        'RESTORE QA: nine notes, image and 100 deletions in ${clock.elapsedMilliseconds}ms at 100ms/request',
      );
      final reads = server.downloads;
      final requests = server.requests;
      for (var i = 0; i < 2; i++) {
        final outcome = await refreshExternalSession(
          b.session,
          isCurrent: () => true,
          progress: () => externalSyncProgress(
            connections: b.session.connections.connections.values,
            progress: b.session.scheduler.progress,
            automatic: false,
          ),
        );
        expect(outcome, SyncRefreshOutcome.complete);
      }
      expect(server.uploads, writes);
      expect(server.downloads, reads);
      expect(
        server.requests - requests,
        2,
        reason: 'Each unchanged refresh only checks the cursor',
      );

      // Publish a real remote edit while B still has the old image note.
      await a.db.update(
        'note',
        {'title': 'New title from A', 'updated_at': '2031-01-01T00:00:00.000Z'},
        where: 'sync_id = ?',
        whereArgs: ['restore-note-0'],
      );
      await a.sync();
      final writesAfterEdit = server.uploads;
      await AppState.init();
      AppState.db = b.db;
      final stale = await Note.fromJsonAsync(row);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: [
            ...AppLocalizations.localizationsDelegates,
            FlutterQuillLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NoteEditor(note: stale),
                  ),
                ),
                child: const Text('Open stale note'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open stale note'));
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditor), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Open stale note'), findsOneWidget);
      Future<Map<String, Object?>> localNote() async => (await b.db.query(
        'note',
        where: 'sync_id = ?',
        whereArgs: ['restore-note-0'],
      )).single;
      expect(
        await localNote(),
        row,
        reason: 'An untouched editor must leave the stored revision intact',
      );
      await b.sync();
      expect((await localNote())['title'], 'New title from A');
      expect(
        server.uploads,
        writesAfterEdit,
        reason: 'A stale editor visit must produce zero upstream writes',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      debugPrint(
        'SYNC QA PASS: closing a stale image note preserves its row and fetches the newer title with zero uploads',
      );

      // Exercise real replica notifications while the user has two cards selected.
      final sort = NoteSortService();
      await sort.init();
      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: [
              ...AppLocalizations.localizationsDelegates,
              FlutterQuillLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Notes()),
          ),
        );
        final cards = find.byType(NoteCard).hitTestable();
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (cards.evaluate().length < 2 &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final selected = tester
            .widgetList<NoteCard>(cards)
            .take(2)
            .map((c) => c.note.syncId!)
            .toList();
        expect(selected, hasLength(2));
        await tester.longPress(cards.first);
        await tester.pumpAndSettle();
        final second = find.byWidgetPredicate(
          (w) => w is NoteCard && w.note.syncId == selected.last,
        );
        await tester.ensureVisible(second);
        await tester.tap(second);
        await tester.pumpAndSettle();
        Iterable<String?> selectedIds() =>
            AppState.selectedNotes.map((note) => note.syncId);
        expect(selectedIds(), selected);
        final unrelated = List.generate(
          9,
          (i) => 'restore-note-$i',
        ).firstWhere((id) => !selected.contains(id));
        Future<void> publishEdit(
          String id,
          Map<String, Object?> changes,
        ) async {
          await a.db.update(
            'note',
            changes,
            where: 'sync_id = ?',
            whereArgs: [id],
          );
          await a.sync();
          await b.sync();
          await tester.pumpAndSettle();
        }

        await publishEdit(unrelated, {
          'title': 'Unrelated edit',
          'updated_at': '2032-01-01T00:00:00.000Z',
        });
        expect(selectedIds(), selected);
        await publishEdit(selected.first, {
          'title': 'Updated selected note',
          'updated_at': '2032-01-02T00:00:00.000Z',
        });
        expect(selectedIds(), selected);
        expect(AppState.selectedNotes.first.title, 'Updated selected note');
        await publishEdit(selected.last, {
          'archived': 1,
          'updated_at': '2032-01-03T00:00:00.000Z',
        });
        expect(selectedIds(), [selected.first]);
        debugPrint(
          'SYNC QA PASS: unrelated edits retain selection, selected cards use the new revision, and archiving removes only the affected card',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        AppState.selectedNotes = [];
        await sort.dispose();
      }
      final priorUploads = server.uploads;
      final fresh = await _Replica.create(
        files,
        p.join(root, 'fresh-logout'),
        server,
        restoreOnStart: true,
      );
      replicas.add(fresh);
      AppState.db = fresh.db;
      await Label.fixLabels();
      await fresh.session.scheduler.waitForIdle();
      expect(await fresh.db.query('note', columns: ['id']), hasLength(9));
      expect(server.uploads, priorUploads);

      Future<SyncLogoutState> logoutState() => inspectSyncBeforeLogout(
        database: fresh.db,
        firebaseAccountId: 'isolated-platform-qa',
        scope: fresh.session.engine.store.scope,
        externalReplicaId: fresh.adapter.connectionId,
        metadataReady: true,
        isCurrent: () => fresh.session.isCurrent,
      );
      Future<int> pendingNotes(String replicaId) =>
          SyncMutationJournal.pendingNotesForProvider(
            fresh.db,
            fresh.session.engine.store.scope,
            replicaId,
          );
      expect(await pendingNotes(fresh.adapter.connectionId), 0);
      // A new provider must receive the nine notes and 100 deletion records.
      expect(await pendingNotes('another-provider'), 109);
      expect(await logoutState(), SyncLogoutState.complete);
      await fresh.db.update(
        'note',
        {'title': 'Local edit before logout'},
        where: 'sync_id = ?',
        whereArgs: ['restore-note-0'],
      );
      expect(await pendingNotes(fresh.adapter.connectionId), 1);
      expect(await logoutState(), SyncLogoutState.pending);
    },
  );
  const automatic = bool.fromEnvironment('AUTOMATIC_SYNC_EMULATOR_TEST');
  if (automatic) {
    testWidgets(
      'automatic replication through real Firebase emulator hints',
      _automaticMatrix,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
  testWidgets(
    'platform replica matrix: rich content, media, edits and recovery',
    (tester) async {
      initializeDb();
      final files = await fileSystem();
      final run = DateTime.now().microsecondsSinceEpoch;
      final root = p.join(await files.documentDir, 'sync-qa-$run');
      final server = _DropboxBoundary();
      final replicas = <_Replica>[];
      Future<_Replica> create(String name) async {
        final replica = await _Replica.create(
          files,
          p.join(root, name),
          server,
        );
        replicas.add(replica);
        return replica;
      }

      addTearDown(() async {
        for (final replica in replicas) {
          await replica.session.close();
          replica.client.close();
          await replica.db.close();
          await deleteDatabase(replica.db.path);
        }
        await _deleteTestFiles(files, root);
      });
      final a = await create('a');
      final b = await create('b');
      var revision = 0;
      String stamp() =>
          DateTime.utc(2030)
              .add(Duration(seconds: revision++))
              .toIso8601String();
      final image = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNwWXXmPwAFqgK6oQQFNwAAAABJRU5ErkJggg==',
      );
      final audio = Uint8List.fromList(List.generate(128, (i) => i));
      final sketch = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'strokes': [
              SketchStroke(
                points: '10,20,0.5;30,40,0.5;',
                color: Colors.indigo,
                size: 6,
              ).toString(),
            ],
            'bgColor': Colors.white.toARGB32(),
            'pagePattern': 'blank',
            'aspectRatio': 1.0,
          }),
        ),
      );
      final expected = {'image': image, 'audio': audio, 'sketch': sketch};
      final attachments = <Map<String, dynamic>>[];
      for (final entry in expected.entries) {
        final source = p.join(a.root, '${entry.key}.bin');
        await files.writeBytes(source, entry.value);
        attachments.add({
          'id': entry.key,
          'type': entry.key,
          'data': switch (entry.key) {
            'sketch' => {'strokesFilePath': source, 'aspectRatio': 1.0},
            'audio' => {'src': source, 'length': 128, 'title': 'QA recording'},
            _ => {
              'src': source,
              'size': entry.value.length,
              'index': 0,
              'aspectRatio': '1:1',
              'lastModified': '',
            },
          },
        });
      }
      String content(int version) => jsonEncode([
        {'insert': 'Sync QA $version\n'},
        {'insert': 'Complete task'},
        {
          'insert': '\n',
          'attributes': {'list': version.isEven ? 'unchecked' : 'checked'},
        },
        {
          'insert': {
            NoteTableData.type:
                NoteTableData(rows: 2, columns: 2, id: 'qa-table').withCell(
                  0,
                  1,
                  [
                    {'insert': 'Cell $version\n'},
                  ],
                ).toJson(),
          },
        },
        {'insert': '\n'},
      ]);
      await a.db.insert('note', {
        'id': 1,
        'sync_id': 'qa-note',
        'title': 'Synthetic QA',
        'content': content(0),
        'created_at': stamp(),
        'updated_at': stamp(),
        'attachments': jsonEncode(attachments),
      });
      await a.sync();
      await b.sync();
      expect((await b.row())['content'], content(0));
      await b.verifyMedia(expected);
      debugPrint(
        'SYNC QA PASS: initial text/table/task/image/audio/sketch transfer',
      );

      final received =
          jsonDecode((await b.row())['attachments'] as String) as List;
      final drawing = SketchData.fromJson(
        Map<String, dynamic>.from(received.last['data'] as Map),
      );
      expect(
        (await SketchStrokesFileService.hydrate(drawing)).hasStrokes,
        isTrue,
      );
      drawing.previewImage = p.join(b.root, 'preview.jpg');
      expect(
        await SketchPreviewGenerator.generatePreview(
          drawing,
          updateCache: false,
        ),
        isTrue,
      );
      final codec = await ui.instantiateImageCodec(
        await files.readBytes(drawing.previewImage!),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(1));
      expect(frame.image.height, greaterThan(1));
      frame.image.dispose();
      codec.dispose();
      debugPrint(
        'SYNC QA PASS: downloaded sketch renders a decodable local preview',
      );

      for (var edit = 1; edit <= 6; edit++) {
        final writer = edit.isOdd ? b : a;
        final reader = edit.isOdd ? a : b;
        await writer.db.update('note', {
          'content': content(edit),
          'updated_at': stamp(),
        }, where: "sync_id = 'qa-note'");
        await writer.sync();
        await reader.sync();
        expect((await reader.row())['content'], content(edit));
        await reader.verifyMedia(expected);
      }
      debugPrint(
        'SYNC QA PASS: six alternating-device edits retain tables/tasks/media',
      );

      final updated =
          jsonDecode((await b.row())['attachments'] as String) as List;
      final imagePath = updated.first['data']['src'] as String;
      final replacement = Uint8List.fromList([...image, 0]);
      await files.writeBytes(imagePath, replacement);
      updated.first['data']['size'] = replacement.length;
      updated.first['data']['lastModified'] = 'replacement';
      expected['image'] = replacement;
      await b.db.update('note', {
        'attachments': jsonEncode(updated),
        'updated_at': stamp(),
      }, where: "sync_id = 'qa-note'");
      await b.sync();
      await a.sync();
      await a.verifyMedia(expected);
      debugPrint('SYNC QA PASS: media replacement reaches the other replica');

      final restored = await create('clean-login');
      await restored.sync();
      expect((await restored.row())['content'], content(6));
      await restored.verifyMedia(expected);
      final fileCount = server.files.length;
      await a.sync();
      await b.sync();
      await restored.sync();
      expect(
        server.files.length,
        fileCount,
        reason: 'No echo uploads after convergence',
      );
      debugPrint(
        'SYNC QA PASS: empty replica restores all media without echo uploads',
      );

      await a.db.delete('note', where: "sync_id = 'qa-note'");
      await a.sync();
      await b.sync();
      await restored.sync();
      expect(await b.db.query('note'), isEmpty);
      expect(await restored.db.query('note'), isEmpty);
      debugPrint('SYNC QA PASS: deletion converges on both receivers');
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text(
                'SYNC QA PASSED\nRich content · media · edits · restore · deletion',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    },
    skip: automatic,
  );
}

Future<void> _deleteTestFiles(FileSystem files, String directory) async {
  for (final entry in await files.list(directory)) {
    final path = p.isAbsolute(entry) ? entry : p.join(directory, entry);
    if (!p.isWithin(directory, path)) {
      throw StateError('Invalid test file path');
    }
    if (await files.isDirectory(path)) {
      await _deleteTestFiles(files, path);
    } else {
      await files.delete(path);
    }
  }
  // Some file-system implementations remove only files; empty directories
  // can remain, but no test media or encrypted payload is retained.
  await files.delete(directory);
}

Future<void> _automaticMatrix(WidgetTester tester) async {
  // Matches functions/test/support/seedAutomaticSync.cjs. All credentials and
  // encryption material here are public disposable fixtures, never app secrets.
  const uid = 'automatic-sync-qa';
  const options = FirebaseOptions(
    apiKey: 'fake-api-key',
    appId: '1:123:web:automatic-sync-qa',
    messagingSenderId: '123',
    projectId: 'demo-better-keep-signals',
  );
  final apps = <FirebaseApp>[];
  final replicas = <_Replica>[];
  initializeDb();
  final files = await fileSystem();
  final root = p.join(
    await files.documentDir,
    'automatic-qa-${DateTime.now().microsecondsSinceEpoch}',
  );
  final server = _DropboxBoundary();
  addTearDown(() async {
    for (final replica in replicas) {
      await replica.session.close();
      replica.client.close();
      await replica.db.close();
      await deleteDatabase(replica.db.path);
    }
    await _deleteTestFiles(files, root);
    for (final app in apps) {
      await FirebaseAuth.instanceFor(app: app).signOut();
      await FirebaseFirestore.instanceFor(app: app).terminate();
      await app.delete();
    }
  });
  Future<_Replica> device(String id) async {
    final app = await Firebase.initializeApp(
      name: 'automatic-$id',
      options: options,
    );
    apps.add(app);
    final auth = FirebaseAuth.instanceFor(app: app);
    await auth.useAuthEmulator('127.0.0.1', 39099);
    final db = FirebaseFirestore.instanceFor(app: app);
    db.useFirestoreEmulator('127.0.0.1', 38183, automaticHostMapping: false);
    db.settings = const Settings(persistenceEnabled: false);
    final signedIn = await auth.signInWithEmailAndPassword(
      email: 'automatic-sync-qa@example.test',
      password: 'Disposable-QA-Only-123!',
    );
    expect(signedIn.user!.uid, uid);
    expect((await signedIn.user!.getIdTokenResult()).claims!['plan'], 'lite');
    final replica = await _Replica.create(
      files,
      p.join(root, id),
      server,
      uid: uid,
      firestore: db,
      deviceId: id,
    );
    replicas.add(replica);
    await replica.session.scheduler.waitForIdle();
    return replica;
  }

  Future<void> until(Future<bool> Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 50));
    while (!await ready()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'Automatic sync timed out: ${replicas.map((r) => r.session.scheduler.progress)}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<bool> hasTitle(_Replica device, String title) async {
    final rows = await device.db.query('note');
    return rows.length == 1 && rows.single['title'] == title;
  }

  final a = await device('device-a');
  final b = await device('device-b');
  final image = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNwWXXmPwAFqgK6oQQFNwAAAABJRU5ErkJggg==',
  );
  final imagePath = p.join(a.root, 'image.png');
  await files.writeBytes(imagePath, image);
  final content = jsonEncode([
    {'insert': 'Automatic fixture\n'},
    {'insert': 'Task'},
    {
      'insert': '\n',
      'attributes': {'list': 'checked'},
    },
    {
      'insert': {
        NoteTableData.type:
            NoteTableData(rows: 2, columns: 2, id: 'automatic-table').withCell(
              0,
              1,
              [
                {'insert': 'Synced cell\n'},
              ],
            ).toJson(),
      },
    },
    {'insert': '\n'},
  ]);
  await a.db.insert('note', {
    'id': 1,
    'sync_id': 'automatic-note',
    'title': 'First automatic save',
    'content': content,
    'created_at': '2030-01-01T00:00:00.000Z',
    'updated_at': '2030-01-01T00:00:01.000Z',
    'attachments': jsonEncode([
      {
        'id': 'image',
        'type': 'image',
        'data': {
          'src': imagePath,
          'size': image.length,
          'index': 0,
          'aspectRatio': '1:1',
          'lastModified': '',
        },
      },
    ]),
  });
  a.session.localChanged();
  await until(() => hasTitle(b, 'First automatic save'));
  expect((await b.row())['content'], content);
  await b.verifyMedia({'image': image});
  debugPrint(
    'AUTOMATIC QA PASS: save → encrypted provider commit → Firestore hint → second replica, with table/task/image',
  );

  final received = jsonDecode((await b.row())['attachments'] as String) as List;
  final replacement = Uint8List.fromList([...image, 0]);
  await files.writeBytes(received.single['data']['src'] as String, replacement);
  received.single['data']['size'] = replacement.length;
  received.single['data']['lastModified'] = 'replacement';
  await b.db.update('note', {
    'title': 'Edited on second device',
    'updated_at': '2030-01-01T00:00:02.000Z',
    'attachments': jsonEncode(received),
  }, where: "sync_id = 'automatic-note'");
  b.session.localChanged();
  await until(() => hasTitle(a, 'Edited on second device'));
  await a.verifyMedia({'image': replacement});
  debugPrint(
    'AUTOMATIC QA PASS: reverse edit and media replacement without manual sync',
  );

  b.session.setForeground(false);
  await a.db.update('note', {
    'title': 'While receiver sleeps',
    'updated_at': '2030-01-01T00:00:03.000Z',
  }, where: "sync_id = 'automatic-note'");
  a.session.localChanged();
  final signalRef = FirebaseFirestore.instanceFor(app: apps.first)
      .doc('users/$uid/storage_sync_signals/dropbox');
  await until(
    () async =>
        (await signalRef.get(const GetOptions(source: Source.server)))
            .data()?['deviceId'] ==
        'device-a',
  );
  expect(await hasTitle(b, 'Edited on second device'), isTrue);
  b.session.setForeground(true);
  await until(() => hasTitle(b, 'While receiver sleeps'));
  await a.session.scheduler.waitForIdle();
  await b.session.scheduler.waitForIdle();
  // Drain the apply debounce before measuring a full former polling interval.
  await Future<void>.delayed(const Duration(seconds: 3));
  final requests = server.requests;
  final signalToken = (await signalRef.get(
    const GetOptions(source: Source.server),
  )).data()!['token'];
  await Future<void>.delayed(const Duration(seconds: 35));
  expect(
    server.requests,
    requests,
    reason: 'Idle clients must not poll providers',
  );
  expect(
    (await signalRef.get(const GetOptions(source: Source.server)))
        .data()!['token'],
    signalToken,
  );
  debugPrint(
    'AUTOMATIC QA PASS: background/resume catches up, no idle polling or notification echo',
  );

  a.session.setAutomatic(false);
  b.session.setAutomatic(false);
  await a.db.update('note', {
    'title': 'Manual only',
    'updated_at': '2030-01-01T00:00:04.000Z',
  }, where: "sync_id = 'automatic-note'");
  a.session.localChanged();
  await Future<void>.delayed(const Duration(seconds: 3));
  expect(await hasTitle(b, 'While receiver sleeps'), isTrue);
  expect(server.requests, requests);
  await a.session.scheduler.syncNow();
  await b.session.scheduler.syncNow();
  expect(await hasTitle(b, 'Manual only'), isTrue);
  expect(
    (await signalRef.get(const GetOptions(source: Source.server)))
        .data()!['token'],
    signalToken,
  );
  debugPrint(
    'AUTOMATIC QA PASS: disabling automatic access stops triggers but manual sync still transfers notes',
  );
}

class _ReadyConnection extends ChangeNotifier
    implements StorageConnectionController {
  _ReadyConnection(StorageConnection connection, SyncProviderAdapter adapter)
    : connections = {connection.provider: connection},
      adapters = [adapter];
  @override
  final Map<String, StorageConnection> connections;
  @override
  final List<SyncProviderAdapter> adapters;
  @override
  bool isSelected(String provider) => connections.containsKey(provider);
  @override
  Future<void> waitForMetadata() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Replica {
  _Replica(
    this.db,
    this.root,
    this.files,
    this.session,
    this.adapter,
    this.client,
  );
  final Database db;
  final String root;
  final FileSystem files;
  final LibrarySyncSession session;
  final FileSyncAdapter adapter;
  final http.Client client;
  static Future<_Replica> create(
    FileSystem files,
    String root,
    _DropboxBoundary server, {
    String uid = 'isolated-platform-qa',
    FirebaseFirestore? firestore,
    String deviceId = 'synthetic-device',
    bool restoreOnStart = false,
    bool notifyModels = false,
    Future<void> Function(SyncAppliedChange)? onApplied,
  }) async {
    await files.createDirectory(root);
    final db = await openDatabase(p.join(root, 'qa.sqlite'));
    await Note.createTable(db);
    await Label.createTable(db);
    await NoteSyncTrack.createTable(db);
    await FileSyncTrack.createTable(db);
    await LabelSyncTrack.createTable(db);
    await NoteSortService.createTable(db);
    await SyncReplicaStore.createTables(db);
    await SyncAttachmentStore.createTable(db);
    await SyncStatusStore.createTable(db);
    await SyncMutationJournal.install(db);
    final cipher = await SyncCipher.create(uid, Uint8List(32));
    final client = MockClient(server.handle);
    final connection = StorageConnection(
      provider: 'dropbox',
      libraryId: cipher.libraryId,
      accountLabel: '',
      encryptedCapability: '',
      generation: 1,
      enabled: true,
      state: 'ready',
    );
    final adapter = FileSyncAdapter(
      connectionId: connection.replicaId,
      cipher: cipher,
      transport: DropboxSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'synthetic',
        libraryId: cipher.libraryId,
      ),
    );
    final session = LibrarySyncSession(
      uid: uid,
      database: db,
      onApplied: notifyModels
          ? ReplicaModelNotifier(
              database: db,
              isCurrent: () => true,
              queueNoteSync: () async {},
              queueLabelSync: () async {},
              reconcileReminders: () {},
              cancelReminder: (_) async {},
            ).apply
          : onApplied,
      files: files,
      documentRoot: root,
      cacheRoot: p.join(root, 'cache'),
      cipher: cipher,
      foreground: firestore != null || restoreOnStart,
      automatic: !restoreOnStart,
      isCurrent: () => true,
      createSignals: firestore == null
          ? null
          : (store, changed) => SyncChangeSignals.firebase(
              uid: uid,
              deviceId: deviceId,
              store: store,
              isCurrent: () => true,
              firestore: firestore,
              onRemoteChange: changed,
            ),
      createConnections: (current) => firestore != null || restoreOnStart
          ? _ReadyConnection(connection, adapter)
          : StorageConnectionController(
              cipher: cipher,
              deviceId: root,
              isCurrent: current,
              call: (_, _) async =>
                  throw StateError('No Firebase calls allowed'),
              readConnection: (_) async => null,
              metadata: const Stream.empty(),
              launchAuthorization: (_) async => false,
            ),
    );
    return _Replica(db, root, files, session, adapter, client);
  }

  Future<void> sync() async {
    await session.engine.sync(adapter);
    expect(session.content.captureFailures, isEmpty);
  }

  Future<Map<String, Object?>> row() async => (await db.query('note')).single;
  Future<void> verifyMedia(Map<String, Uint8List> expected) async {
    final attachments =
        jsonDecode((await row())['attachments'] as String) as List;
    expect(attachments.length, expected.length);
    for (final attachment in attachments) {
      final data = attachment['data'] as Map;
      final source = (data['src'] ?? data['strokesFilePath']) as String;
      expect(
        await session.attachments.read(source),
        expected[attachment['id']],
      );
      expect(source, startsWith(root));
    }
  }
}

class _DropboxBoundary {
  final files = <String, Uint8List>{};
  final sessions = <String, Uint8List>{};
  int sessionSequence = 0;
  int requests = 0, uploads = 0, downloads = 0;
  int concurrentDownloads = 0, maxConcurrentDownloads = 0;
  Duration delay = Duration.zero;
  int pageSize = 100;
  int? failDownloadAt, loseUploadAckAt;
  bool offline = false;
  Future<http.Response> handle(http.Request request) async {
    requests++;
    if (offline) return http.Response('unavailable', 503);
    final downloading = request.url.path == '/2/files/download';
    final downloadNumber = downloading ? downloads + 1 : null;
    if (downloading) {
      downloads++;
      concurrentDownloads++;
      if (concurrentDownloads > maxConcurrentDownloads) {
        maxConcurrentDownloads = concurrentDownloads;
      }
    }
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    if (downloading) {
      concurrentDownloads--;
      if (downloadNumber == failDownloadAt) {
        return http.Response('unavailable', 503);
      }
    }
    expect(request.headers['authorization'], 'Bearer synthetic');
    final args =
        jsonDecode(request.headers['dropbox-api-arg'] ?? request.body) as Map;
    switch (request.url.path) {
      case '/2/files/create_folder_v2':
        return http.Response('{}', 200);
      case '/2/files/list_folder':
      case '/2/files/list_folder/continue':
        final offset = int.parse(args['cursor'] as String? ?? '0');
        final end = (offset + pageSize).clamp(0, files.length);
        return http.Response(
          jsonEncode({
            'entries': files.keys
                .skip(offset)
                .take(pageSize)
                .map((path) => {'.tag': 'file', 'name': p.basename(path)})
                .toList(),
            'cursor': '$end',
            'has_more': end < files.length,
          }),
          200,
        );
      case '/2/files/upload_session/start':
        expect(args['close'], isTrue);
        final id = '${++sessionSequence}';
        sessions[id] = Uint8List.fromList(request.bodyBytes);
        return http.Response(jsonEncode({'session_id': id}), 200);
      case '/2/files/upload_session/finish_batch_v2':
        final results = <Map<String, Object?>>[];
        for (final entry in args['entries'] as List) {
          final cursor = entry['cursor'] as Map;
          final commit = entry['commit'] as Map;
          final bytes = sessions.remove(cursor['session_id'])!;
          expect(cursor['offset'], bytes.length);
          expect(commit['mode'], 'add');
          expect(commit['autorename'], isFalse);
          expect(commit['strict_conflict'], isTrue);
          final path = commit['path'] as String;
          uploads++;
          if (files.containsKey(path)) {
            results.add({
              '.tag': 'failure',
              'failure': {
                '.tag': 'path',
                'path': {'.tag': 'conflict'},
              },
            });
          } else {
            files[path] = bytes;
            results.add({'.tag': 'success', 'name': p.basename(path)});
          }
          if (uploads == loseUploadAckAt) return http.Response('lost ack', 503);
        }
        return http.Response(jsonEncode({'entries': results}), 200);
      case '/2/files/upload':
        uploads++;
        final path = args['path'] as String;
        if (files.containsKey(path)) {
          return http.Response('{"error_summary":"path/conflict/file"}', 409);
        }
        files[path] = Uint8List.fromList(request.bodyBytes);
        if (uploads == loseUploadAckAt) return http.Response('lost ack', 503);
        return http.Response('{}', 200);
      case '/2/files/download':
        return http.Response.bytes(files[args['path']]!, 200);
      default:
        throw StateError('Unexpected Dropbox route ${request.url.path}');
    }
  }
}

// Opt-in stress fixtures are supplied from a local defines file; no live
// credentials, downloaded photos, or generated libraries are committed.
Future<void> _stressMatrix(WidgetTester tester) async {
  const showGrid = bool.fromEnvironment('SYNC_STRESS_UI');
  final response = await http.get(
    Uri.parse(const String.fromEnvironment('SYNC_STRESS_FIXTURE_URL')),
  );
  expect(response.statusCode, 200);
  Future<void> report(String stage, [int? milliseconds]) async {
    debugPrint(
      'STRESS PASS $stage${milliseconds == null ? '' : ': ${milliseconds}ms'}',
    );
    const endpoint = String.fromEnvironment('SYNC_STRESS_PROGRESS_URL');
    if (endpoint.isNotEmpty) {
      await http.post(
        Uri.parse(endpoint),
        body: jsonEncode({'stage': stage, 'milliseconds': milliseconds}),
      );
    }
  }

  await report('fixture-loaded');
  final fixture = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
  final data = (fixture['notes'] as List).cast<Map<String, dynamic>>();
  final photos = (fixture['images'] as List)
      .map((value) => base64Decode(value as String))
      .toList();
  expect(data.length, 1000);
  expect(photos, isNotEmpty);
  initializeDb();
  final files = await fileSystem();
  final root = p.join(
    await files.documentDir,
    'sync-stress-${DateTime.now().microsecondsSinceEpoch}',
  );
  final server = _DropboxBoundary();
  final active = <String, _Replica>{};
  Future<_Replica> open(String name) async {
    final replica = await _Replica.create(
      files,
      p.join(root, name),
      server,
      notifyModels: showGrid && name == 'c',
    );
    active[name] = replica;
    return replica;
  }

  Future<void> close(String name) async {
    final replica = active.remove(name)!;
    await replica.session.close();
    replica.client.close();
    await replica.db.close();
  }

  addTearDown(() async {
    for (final name in active.keys.toList()) {
      await close(name);
    }
    for (final name in ['a', 'b', 'c']) {
      await deleteDatabase(p.join(root, name, 'qa.sqlite'));
    }
    await _deleteTestFiles(files, root);
  });
  final timings = <String, int>{};
  Future<void> timed(String name, Future<void> Function() operation) async {
    final clock = Stopwatch()..start();
    await operation();
    timings[name] = clock.elapsedMilliseconds;
    await report(name, clock.elapsedMilliseconds);
  }

  var a = await open('a');
  await report('first-replica-open');
  for (var i = 0; i < photos.length; i++) {
    await files.writeBytes(p.join(a.root, 'pexels-$i.jpg'), photos[i]);
  }
  final expected = <String, Map<String, dynamic>>{};
  await a.db.transaction((txn) async {
    for (var i = 0; i < data.length; i++) {
      final item = data[i];
      final photo = item['imageIndex'] as int;
      final id = 'stress-${i.toString().padLeft(4, '0')}';
      final content = jsonEncode([
        {'insert': '${item['text']}\n'},
      ]);
      expected[id] = {
        'title': item['title'],
        'content': content,
        'imageHash': sha256.convert(photos[photo]).toString(),
      };
      await txn.insert('note', {
        'id': i + 1,
        'sync_id': id,
        'title': item['title'],
        'content': content,
        'created_at': '2030-01-01T00:00:00.000Z',
        'updated_at': '2030-01-01T00:00:01.000Z',
        'attachments': jsonEncode([
          {
            'id': 'image-$i',
            'type': 'image',
            'data': {
              'src': p.join(a.root, 'pexels-$photo.jpg'),
              'size': photos[photo].length,
              'index': 0,
              'aspectRatio': '3:2',
              'lastModified': '',
            },
          },
        ]),
      });
    }
  });
  await report('1000-notes-created');
  Future<void> drain(_Replica replica, {bool downloadOnly = false}) async {
    for (var pass = 0; pass < 30; pass++) {
      await replica.session.engine.sync(
        replica.adapter,
        downloadOnly: downloadOnly,
      );
      expect(replica.session.content.captureFailures, isEmpty);
      if (downloadOnly ||
          (await SyncMutationJournal.pending(
            replica.db,
            replica.session.engine.store.scope,
            limit: 1,
          )).isEmpty) {
        return;
      }
    }
    fail('Capture did not drain in 30 passes');
  }

  Future<void> verify(_Replica replica) async {
    final rows = await replica.db.query('note');
    expect(rows.length, expected.length);
    expect(rows.map((r) => r['sync_id']).toSet(), expected.keys.toSet());
    for (final row in rows) {
      final wanted = expected[row['sync_id']]!;
      expect(row['title'], wanted['title'], reason: '${row['sync_id']} title');
      expect(
        row['content'],
        wanted['content'],
        reason: '${row['sync_id']} content',
      );
      final media = jsonDecode(row['attachments'] as String) as List;
      expect(media.length, 1);
      final bytes = await replica.session.attachments.read(
        media.single['data']['src'] as String,
      );
      expect(bytes, isNotNull);
      expect(
        sha256.convert(bytes).toString(),
        wanted['imageHash'],
        reason: '${row['sync_id']} image',
      );
    }
  }

  // Persist a write but lose its response: retry must not duplicate the commit.
  server.loseUploadAckAt = 137;
  await expectLater(drain(a), throwsA(isA<SyncProviderFailure>()));
  server.loseUploadAckAt = null;
  await close('a');
  a = await open('a');
  var showedUploadProgress = false;
  void observeUpload() {
    final update = a.session.transfers[a.adapter.connectionId];
    if (update?.stage == NoteTransferStage.uploading && update!.done > 0) {
      showedUploadProgress = true;
    }
  }

  a.session.addListener(observeUpload);
  try {
    await timed('upload-after-lost-ack-and-reopen', () => drain(a));
    expect(showedUploadProgress, isTrue);
  } finally {
    a.session.removeListener(observeUpload);
  }
  final committedFiles = server.files.length;
  final writes = server.uploads;
  var b = await open('b');
  server.failDownloadAt = server.downloads + 37;
  await expectLater(
    drain(b, downloadOnly: true),
    throwsA(isA<SyncProviderFailure>()),
  );
  server.failDownloadAt = null;
  await close('b');
  b = await open('b');
  await timed(
    'restore-after-interruption-and-reopen',
    () => drain(b, downloadOnly: true),
  );
  expect(server.uploads, writes);
  await timed('verify-all-1000-notes-and-images', () => verify(b));
  await close('b');
  b = await open('b');
  await verify(
    b,
  ); // Durable local data is usable before contacting the provider.
  final downloads = server.downloads;
  await timed('unchanged-refresh', () => drain(b));
  expect(server.downloads, downloads);
  expect(server.files.length, committedFiles);
  expect(server.uploads, writes);
  server.offline = true;
  await expectLater(drain(b), throwsA(isA<SyncProviderFailure>()));
  await verify(b);
  server.offline = false;
  // Fifty edits from each device, plus an independently newer local winner.
  for (var i = 0; i < 100; i++) {
    final writer = i.isEven ? a : b;
    final id = 'stress-${i.toString().padLeft(4, '0')}';
    final title = 'Edited from ${i.isEven ? 'a' : 'b'} $i';
    expected[id]!['title'] = title;
    await writer.db.update(
      'note',
      {'title': title, 'updated_at': '2030-01-01T00:00:02.000Z'},
      where: 'sync_id = ?',
      whereArgs: [id],
    );
  }
  await b.db.update('note', {
    'title': 'Newest local winner',
    'updated_at': '2030-01-01T00:00:03.000Z',
  }, where: "sync_id = 'stress-0000'");
  expected['stress-0000']!['title'] = 'Newest local winner';
  // Replace twenty images and remove fifty notes while the other device is offline.
  for (var i = 100; i < 120; i++) {
    final id = 'stress-${i.toString().padLeft(4, '0')}';
    final row = (await a.db.query(
      'note',
      where: 'sync_id = ?',
      whereArgs: [id],
    )).single;
    final media = jsonDecode(row['attachments'] as String) as List;
    final photo = ((data[i]['imageIndex'] as int) + 1) % photos.length;
    media.single['data']['src'] = p.join(a.root, 'pexels-$photo.jpg');
    media.single['data']['size'] = photos[photo].length;
    media.single['data']['lastModified'] = 'replacement';
    await a.db.update(
      'note',
      {
        'attachments': jsonEncode(media),
        'updated_at': '2030-01-01T00:00:02.000Z',
      },
      where: 'sync_id = ?',
      whereArgs: [id],
    );
    expected[id]!['imageHash'] = sha256.convert(photos[photo]).toString();
  }
  for (var i = 900; i < 950; i++) {
    final id = 'stress-${i.toString().padLeft(4, '0')}';
    await a.db.delete('note', where: 'sync_id = ?', whereArgs: [id]);
    expected.remove(id);
  }
  await timed('bidirectional-edits-images-deletions', () async {
    await drain(a);
    await drain(b);
    await drain(a);
    await verify(a);
    await verify(b);
  });
  final c = await open('c');
  var displayedChanges = 0;
  var sawBulkProgress = false;
  var renderedDuringBulk = false;
  void reportGridProgress(NoteEvent event) {
    displayedChanges++;
    if (displayedChanges % 100 == 0) {
      final progress = NoteSyncBatch.progress.value;
      if (progress != null && progress.done > 0 && NoteSyncBatch.active.value) {
        sawBulkProgress |= find.byType(BulkSyncProgress).evaluate().isNotEmpty;
        renderedDuringBulk |= find.byType(NoteCard).evaluate().isNotEmpty;
      }
      unawaited(report('visible-grid-applied-$displayedChanges'));
    }
  }

  if (showGrid) {
    Note.on('changed', reportGridProgress);
    await AppState.init();
    AppState.db = c.db;
    AppState.showNotes = NoteType.all;
    AppState.selectedNotes = [];
    AppState.filterLabels = [];
    AppState.currentFolder = null;
    AppState.set('notes_view_mode', NoteViewMode.grid);
    await NoteSortService().init();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: [
          ...AppLocalizations.localizationsDelegates,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Notes()),
      ),
    );
    // Mount with the test binding's default policy. On web, fullyLive during
    // the preceding headless sync stages can leave the first UI pump pending.
    final binding = IntegrationTestWidgetsFlutterBinding.instance;
    final previous = binding.framePolicy;
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    addTearDown(() => binding.framePolicy = previous);
    await tester.pump();
  }
  try {
    await timed(
      'fresh-third-device-restore',
      () => drain(c, downloadOnly: true),
    );
    await verify(c);
    if (showGrid) {
      expect(sawBulkProgress, isTrue);
      expect(renderedDuringBulk, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(NoteCard).evaluate().length, inInclusiveRange(1, 60));
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(NoteCard).evaluate().length, inInclusiveRange(1, 60));
      scroll.jumpTo(0);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(NoteCard).evaluate().length, inInclusiveRange(1, 60));
      await report('visible-grid-restored-${expected.length}-notes');
    }
  } finally {
    if (showGrid) {
      Note.off('changed', reportGridProgress);
      await tester.pumpWidget(const SizedBox.shrink());
      await NoteSortService().dispose();
    }
  }
  final finalWrites = server.uploads;
  // Writers still need to advance their listing cursor past their own commits.
  // That metadata read is expected; it must not cause uploads or reapplication.
  await drain(a);
  await drain(b);
  await drain(c);
  expect(server.uploads, finalWrites);
  final finalDownloads = server.downloads;
  await drain(a);
  await drain(b);
  await drain(c);
  expect(server.uploads, finalWrites);
  expect(server.downloads, finalDownloads);
  debugPrint(
    'STRESS RESULT ${jsonEncode({'notes': data.length, 'finalNotes': expected.length, 'requests': server.requests, 'uploads': server.uploads, 'downloads': server.downloads, 'maxConcurrentDownloads': server.maxConcurrentDownloads, 'timingsMs': timings})}',
  );
}
