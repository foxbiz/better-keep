import 'dart:async';
import 'dart:convert';

import 'package:better_keep/dialogs/unlock_note_dialog.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/settings/sync_issues_page.dart';
import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:better_keep/services/external_sync/external_sync_service.dart';
import 'package:better_keep/services/external_sync/library_replica_content.dart';
import 'package:better_keep/services/external_sync/library_sync_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Content content;
  late _Session session;
  late _Service service;
  setUp(() {
    content = _Content();
    session = _Session(content);
    service = _Service(session);
  });
  tearDown(() {
    service.dispose();
    session.dispose();
  });
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSyncIssuesPage(context, service: service),
            child: const Text('Open issues'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open issues'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'affected notes keep locked titles private and require the existing PIN dialog',
    (tester) async {
      await mount(tester);
      expect(find.text('Visible QA note'), findsOneWidget);
      expect(find.text('Never reveal this title'), findsNothing);
      expect(find.text('Note locked'), findsOneWidget);
      await tester.tap(find.text('Note locked'));
      await tester.pumpAndSettle();
      expect(content.opened, ['locked']);
      expect(find.byType(UnlockNoteDialog), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(UnlockNoteDialog), findsNothing);
      expect(find.byType(SyncIssuesPage), findsOneWidget);
    },
  );

  testWidgets('replacing the session closes its recovery page and PIN prompt', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Note locked'));
    await tester.pumpAndSettle();
    service.session = null;
    service.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(SyncIssuesPage), findsNothing);
    expect(find.byType(UnlockNoteDialog), findsNothing);
    expect(find.text('Open issues'), findsOneWidget);
    expect(tester.takeException()?.toString(), isNull);
  });

  testWidgets('retry refreshes the list and prevents duplicate requests', (
    tester,
  ) async {
    await mount(tester);
    final gate = Completer<void>();
    service.gate = gate;
    await tester.tap(find.text('Retry now'));
    await tester.pump();
    expect(service.calls, 1);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    content.issues = [];
    content.captureFailures.clear();
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('No affected notes to show.'), findsOneWidget);
    expect(find.text('Visible QA note'), findsNothing);
  });

  testWidgets(
    'automatic resolution updates the list without another user action',
    (tester) async {
      await mount(tester);
      content.issues = [];
      content.captureFailures.clear();
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('No affected notes to show.'), findsOneWidget);
    },
  );

  testWidgets('note read failure is sanitized and leaves recovery available', (
    tester,
  ) async {
    content.failOpen = true;
    await mount(tester);
    await tester.tap(find.text('Visible QA note'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "This note couldn't be opened. Try again, or open it on another device.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('/private/secret'), findsNothing);
    expect(find.text('Retry now'), findsOneWidget);
  });

  for (final (outcome, message) in [
    (
      SyncRefreshOutcome.localStorageFailure,
      'Sync could not access data on this device. Try again.',
    ),
    (SyncRefreshOutcome.failed, 'Sync failed'),
    (SyncRefreshOutcome.retryScheduled, 'Sync will retry shortly.'),
  ]) {
    testWidgets('retry displays its actual $outcome instead of stale success', (
      tester,
    ) async {
      service.outcome = outcome;
      await mount(tester);
      await tester.tap(find.text('Retry now'));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(find.text('Sync complete'), findsNothing);
    });
  }

  testWidgets('late completion and coalesced edits preserve Retry feedback', (
    tester,
  ) async {
    await mount(tester);
    service.progress = const SyncProgress(SyncPhase.syncing);
    service.notifyListeners();
    await tester.pump();
    service.outcome = SyncRefreshOutcome.localStorageFailure;
    await tester.tap(find.text('Retry now'));
    await tester.pumpAndSettle();
    const message = 'Sync could not access data on this device. Try again.';
    expect(find.text(message), findsOneWidget);
    service.progress = const SyncProgress(SyncPhase.notesNeedAttention);
    service.notifyListeners();
    Note(syncId: 'visible')
        .notifyWithOrigin('updated', ModelChangeOrigin.remoteSync);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    service.progress = const SyncProgress(SyncPhase.syncing);
    service.notifyListeners();
    await tester.pump();
    expect(find.text(message), findsNothing);
  });

  testWidgets('note changes refresh titles and lock state once per batch', (
    tester,
  ) async {
    await mount(tester);
    final reads = content.reads;
    content.issues[0] = (
      syncId: 'visible',
      title: '',
      locked: true,
      updatedAt: '2026-11-24',
      reason: SyncCaptureFailure.unavailable,
    );
    for (var i = 0; i < 5; i++) {
      Note(syncId: 'visible')
          .notifyWithOrigin('updated', ModelChangeOrigin.local);
    }
    await tester.pumpAndSettle();
    expect(find.text('Visible QA note'), findsNothing);
    expect(find.text('Note locked'), findsNWidgets(2));
    expect(content.reads, reads + 1);
  });

  testWidgets(
    'same-reason recapture refreshes once after a pass, not each progress tick',
    (tester) async {
      await mount(tester);
      final reads = content.reads;
      service.progress = const SyncProgress(SyncPhase.syncing);
      for (var i = 0; i < 10; i++) {
        session.notifyListeners();
      }
      await tester.pump();
      expect(content.reads, reads);
      content.issues[0] = (
        syncId: 'visible',
        title: 'Updated title',
        locked: false,
        updatedAt: null,
        reason: SyncCaptureFailure.unavailable,
      );
      service.progress = const SyncProgress(SyncPhase.notesNeedAttention);
      session.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Updated title'), findsOneWidget);
      expect(content.reads, reads + 1);
    },
  );

  testWidgets('resolved list supersedes stale open error', (tester) async {
    content.failOpen = true;
    await mount(tester);
    await tester.tap(find.text('Visible QA note'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(SyncIssuesPage)),
    )!;
    expect(find.text(l10n.syncNoteOpenFailed), findsOneWidget);
    content.issues = [];
    content.captureFailures.clear();
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('No affected notes to show.'), findsOneWidget);
    expect(find.text(l10n.syncNoteOpenFailed), findsNothing);
  });

  testWidgets('coalesced edit cannot erase a newer open error', (tester) async {
    content.failOpen = true;
    await mount(tester);
    Note(syncId: 'visible')
        .notifyWithOrigin('updated', ModelChangeOrigin.remoteSync);
    await tester.tap(find.text('Visible QA note'));
    await tester.pump();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(SyncIssuesPage)),
    )!;
    expect(find.text(l10n.syncNoteOpenFailed), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(find.text(l10n.syncNoteOpenFailed), findsOneWidget);
    // An edit after the error does supersede that old feedback.
    Note(syncId: 'visible')
        .notifyWithOrigin('updated', ModelChangeOrigin.remoteSync);
    await tester.pumpAndSettle();
    expect(find.text(l10n.syncNoteOpenFailed), findsNothing);
  });

  testWidgets('new affected notes supersede an earlier Retry success', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Retry now'));
    await tester.pumpAndSettle();
    expect(find.text('Sync complete'), findsOneWidget);
    content.captureFailures['note:new'] = SyncCaptureFailure.sourceRead;
    content.issues.add((
      syncId: 'new',
      title: 'New affected note',
      locked: false,
      updatedAt: null,
      reason: SyncCaptureFailure.sourceRead,
    ));
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('New affected note'), findsOneWidget);
    expect(find.text('Sync complete'), findsNothing);
  });

  testWidgets('successful PIN cannot open malformed content in the editor', (
    tester,
  ) async {
    Note.pinContentDecryptOverride = (_, _) async => '{broken-json';
    Note.unlockPostAuthenticationOverride = (_, _) async {};
    addTearDown(() {
      Note.pinContentDecryptOverride = null;
      Note.unlockPostAuthenticationOverride = null;
    });
    content.openedNote = Note(locked: true, content: 'opaque-PIN-ciphertext');
    await mount(tester);
    await tester.tap(find.text('Note locked'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Unlock'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(SyncIssuesPage)),
    )!;
    expect(find.text(l10n.syncNoteOpenFailed), findsOneWidget);
    expect(find.byType(UnlockNoteDialog), findsNothing);
    expect(content.openedNote!.unlocked, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final embed in [
    {
      'note-attachment': {'id': 'qa', 'src': 42},
    },
    {
      'note-table': {'id': 'qa', 'rows': 0, 'columns': 1},
    },
  ]) {
    testWidgets('malformed embed stays on recovery page: $embed', (
      tester,
    ) async {
      content.sourceContent = jsonEncode([
        {'insert': embed},
        {'insert': '\n'},
      ]);
      await mount(tester);
      await tester.tap(find.text('Visible QA note'));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SyncIssuesPage)),
      )!;
      expect(find.text(l10n.syncNoteOpenFailed), findsOneWidget);
      expect(find.text('Retry now'), findsOneWidget);
      expect(find.text('Visible QA note'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow recovery layout supports large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(tester);
    expect(find.text('Retry now'), findsOneWidget);
    expect(tester.takeException()?.toString(), isNull);
  });
}

class _Content implements LibraryReplicaContent {
  @override
  final captureFailures = <String, SyncCaptureFailure>{
    'note:visible': SyncCaptureFailure.unavailable,
    'note:locked': SyncCaptureFailure.unlockRequired,
  };
  List<SyncNoteIssue> issues = [
    (
      syncId: 'visible',
      title: 'Visible QA note',
      locked: false,
      updatedAt: null,
      reason: SyncCaptureFailure.unavailable,
    ),
    (
      syncId: 'locked',
      title: 'Never reveal this title',
      locked: true,
      updatedAt: '2026-01-01',
      reason: SyncCaptureFailure.unlockRequired,
    ),
  ];
  final opened = <String>[];
  bool failOpen = false;
  Note? openedNote;
  String? sourceContent;
  int reads = 0;
  @override
  Future<List<SyncNoteIssue>> affectedNotes() async {
    reads++;
    return List.of(issues);
  }

  @override
  Future<Note?> openAffectedNote(String id) async {
    opened.add(id);
    if (failOpen) throw Exception('/private/secret');
    if (sourceContent != null) {
      return Note.fromJsonAsync({'content': sourceContent}, strict: true);
    }
    return openedNote ??
        Note(id: 1, syncId: id, locked: true, title: 'Never reveal this title');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends ChangeNotifier implements LibrarySyncSession {
  _Session(this.content);
  @override
  final LibraryReplicaContent content;
  @override
  bool get isCurrent => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service extends ChangeNotifier implements ExternalSyncService {
  _Service(this.session);
  @override
  LibrarySyncSession? session;
  @override
  SyncProgress progress = const SyncProgress(SyncPhase.complete);
  Completer<void>? gate;
  int calls = 0;
  SyncRefreshOutcome outcome = SyncRefreshOutcome.complete;
  @override
  Future<SyncRefreshOutcome?> refreshWithOutcome() async {
    calls++;
    await gate?.future;
    return outcome;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
