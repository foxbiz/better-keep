import 'dart:async';

import 'package:better_keep/pages/home/notes.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    NoteSyncService.refreshOperationOverride = null;
    LabelSyncService.refreshOperationOverride = null;
  });

  test('note refresh requested during startup sync waits its turn', () async {
    await _expectRefreshesAreSerialized(
      refresh: NoteSyncService().refresh,
      installOperation: (operation) {
        NoteSyncService.refreshOperationOverride = operation;
      },
    );
  });

  test('label refresh requested during startup sync waits its turn', () async {
    await _expectRefreshesAreSerialized(
      refresh: LabelSyncService().refresh,
      installOperation: (operation) {
        LabelSyncService.refreshOperationOverride = operation;
      },
    );
  });

  test('notes reload waits for both serialized refreshes', () async {
    final releaseNotes = Completer<void>();
    final releaseLabels = Completer<void>();
    final events = <String>[];

    final sequence = runNotesRefreshSequence(
      refreshNotes: () async {
        events.add('notes-start');
        await releaseNotes.future;
        events.add('notes-end');
      },
      refreshLabels: () async {
        events.add('labels-start');
        await releaseLabels.future;
        events.add('labels-end');
      },
      reloadNotes: () async {
        events.add('reload');
      },
    );

    await pumpEventQueue();
    expect(events, ['notes-start']);

    releaseNotes.complete();
    await pumpEventQueue();
    expect(events, ['notes-start', 'notes-end', 'labels-start']);

    releaseLabels.complete();
    await sequence;
    expect(events, [
      'notes-start',
      'notes-end',
      'labels-start',
      'labels-end',
      'reload',
    ]);
  });
}

Future<void> _expectRefreshesAreSerialized({
  required Future<void> Function() refresh,
  required void Function(Future<void> Function()) installOperation,
}) async {
  final releases = [Completer<void>(), Completer<void>()];
  final events = <String>[];
  var invocation = 0;
  installOperation(() async {
    final current = invocation++;
    events.add('start-$current');
    await releases[current].future;
    events.add('end-$current');
  });

  final first = refresh();
  await pumpEventQueue();
  final second = refresh();
  await pumpEventQueue();

  expect(events, ['start-0']);

  releases[0].complete();
  await first;
  await pumpEventQueue();
  expect(events, ['start-0', 'end-0', 'start-1']);

  releases[1].complete();
  await second;
  expect(events, ['start-0', 'end-0', 'start-1', 'end-1']);
}
