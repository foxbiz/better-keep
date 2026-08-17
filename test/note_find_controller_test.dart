import 'dart:async';

import 'package:better_keep/pages/note_editor/note_find_controller.dart';
import 'package:better_keep/services/note_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'keeps all matches navigable while bounding rendered highlights',
    () async {
      final text = List.filled(3005, 'x').join(' ');
      final activated = <NoteSearchMatch>[];
      final controller = NoteFindController(
        snapshot: () => (document: NoteSearchDocument(text: text), revision: 0),
        onMatchActivated: activated.add,
      );
      addTearDown(controller.dispose);

      controller.open(anchorOffset: text.length - 10, seed: 'x');
      await pumpEventQueue(times: 30);

      expect(controller.matchCount, 3005);
      expect(
        controller.renderedMatches,
        hasLength(NoteFindController.maxRenderedMatches),
      );
      expect(controller.currentMatch, isNotNull);
      expect(
        controller.renderedMatches.any(
          (match) => match.start == controller.currentMatch!.start,
        ),
        isTrue,
      );
      final before = controller.activeIndex;
      controller.next();
      expect(controller.activeIndex, (before + 1) % controller.matchCount);
      expect(activated, isNotEmpty);
    },
  );

  test(
    'smart mode is search-only and collapses replacement controls',
    () async {
      final controller = NoteFindController(
        snapshot: () => (
          document: const NoteSearchDocument(text: 'meeting tomorrow'),
          revision: 1,
        ),
        onMatchActivated: (_) {},
      );
      addTearDown(controller.dispose);

      controller.open(anchorOffset: 0, seed: 'meeting');
      controller.showReplace();
      expect(controller.replaceExpanded, isTrue);

      controller.setMode(NoteSearchMode.smart);
      await pumpEventQueue(times: 20);

      expect(controller.replaceExpanded, isFalse);
      expect(controller.canReplace, isFalse);
    },
  );

  test(
    'explicit replace exits persisted smart mode and reruns search',
    () async {
      final controller = NoteFindController(
        snapshot: () => (
          document: const NoteSearchDocument(text: 'meeting tomorrow'),
          revision: 1,
        ),
        onMatchActivated: (_) {},
      );
      addTearDown(controller.dispose);

      controller.open(anchorOffset: 0, seed: 'mtg');
      controller.setMode(NoteSearchMode.smart);
      await pumpEventQueue(times: 20);
      expect(controller.matchCount, 1);

      controller.close();
      expect(controller.mode, NoteSearchMode.smart);
      controller.open(anchorOffset: 0, seed: 'mtg');
      controller.showReplace();
      await pumpEventQueue(times: 20);

      expect(controller.queryController.text, 'mtg');
      expect(controller.mode, NoteSearchMode.literal);
      expect(controller.replaceExpanded, isTrue);
      expect(controller.matchCount, 0);
    },
  );

  test('discards stale asynchronous search results', () async {
    final pending = <Completer<NoteSearchResult>>[];
    var revision = 0;
    final controller = NoteFindController(
      snapshot: () => (
        document: const NoteSearchDocument(text: 'alpha omega'),
        revision: revision,
      ),
      onMatchActivated: (_) {},
      currentRevision: () => revision,
      searchRunner: (document, query) {
        final completer = Completer<NoteSearchResult>();
        pending.add(completer);
        return completer.future;
      },
    );
    addTearDown(controller.dispose);

    controller.open(anchorOffset: 0, seed: 'alpha');
    expect(pending, hasLength(1));

    revision = 1;
    controller.queryController.text = 'omega';
    controller.scheduleSearch(immediate: true);
    expect(pending, hasLength(2));

    pending.first.complete(
      const NoteSearchResult(matches: [NoteSearchMatch(start: 0, end: 5)]),
    );
    await pumpEventQueue();
    expect(controller.matches, isEmpty);

    pending.last.complete(
      const NoteSearchResult(matches: [NoteSearchMatch(start: 6, end: 11)]),
    );
    await pumpEventQueue();
    expect(controller.currentMatch?.start, 6);
  });
}
