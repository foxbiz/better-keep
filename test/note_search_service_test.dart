import 'package:better_keep/services/note_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = NoteSearchEngine();

  group('literal search', () {
    test('supports case and whole-word matching with UTF-16 offsets', () {
      const document = NoteSearchDocument(text: 'Alpha alphabet alpha café');

      final insensitive = engine.search(
        document,
        const NoteSearchQuery(text: 'alpha'),
      );
      expect(insensitive.matches.map((match) => (match.start, match.end)), [
        (0, 5),
        (6, 11),
        (15, 20),
      ]);

      final wholeWord = engine.search(
        document,
        const NoteSearchQuery(text: 'alpha', wholeWord: true),
      );
      expect(wholeWord.matches.map((match) => (match.start, match.end)), [
        (0, 5),
        (15, 20),
      ]);

      final caseSensitive = engine.search(
        document,
        const NoteSearchQuery(text: 'Alpha', caseSensitive: true),
      );
      expect(caseSensitive.matches, hasLength(1));
      expect(caseSensitive.matches.single.start, 0);
    });

    test('keeps literal replacement characters literal', () {
      const document = NoteSearchDocument(text: 'one one');
      final plan = engine.buildReplacementPlan(
        document: document,
        query: const NoteSearchQuery(text: 'one'),
        replacement: r'$1\n',
      );

      expect(plan.isValid, isTrue);
      expect(plan.edits, hasLength(2));
      expect(plan.edits.first.replacement, r'$1\n');
    });
  });

  group('regular expression search', () {
    test('reports invalid and zero-length-only expressions', () {
      const document = NoteSearchDocument(text: 'alpha\nbeta');

      expect(
        engine
            .search(
              document,
              const NoteSearchQuery(
                text: '(',
                mode: NoteSearchMode.regularExpression,
              ),
            )
            .error,
        NoteSearchError.invalidRegularExpression,
      );
      expect(
        engine
            .search(
              document,
              const NoteSearchQuery(
                text: r'^',
                mode: NoteSearchMode.regularExpression,
              ),
            )
            .error,
        NoteSearchError.zeroLengthMatchesUnsupported,
      );
    });

    test('expands numbered, named, escaped, and whole-match replacements', () {
      const document = NoteSearchDocument(text: 'item-42');
      final plan = engine.buildReplacementPlan(
        document: document,
        query: const NoteSearchQuery(
          text: r'(item)-(?<number>\d+)',
          mode: NoteSearchMode.regularExpression,
        ),
        replacement: r'${number}:$1:$0:$$:\n:\t:\\',
      );

      expect(plan.isValid, isTrue);
      expect(plan.edits, hasLength(1));
      expect(plan.edits.single.replacement, '42:item:item-42:\$:\n:\t:\\');
    });

    test('rejects unknown replacement references', () {
      const document = NoteSearchDocument(text: 'item');
      final plan = engine.buildReplacementPlan(
        document: document,
        query: const NoteSearchQuery(
          text: r'(item)',
          mode: NoteSearchMode.regularExpression,
        ),
        replacement: r'$2',
      );

      expect(plan.error, NoteSearchError.invalidReplacementReference);
      expect(plan.edits, isEmpty);
    });
  });

  group('smart search', () {
    test('finds spelling transpositions and ordered abbreviations', () {
      const document = NoteSearchDocument(
        text: 'Please receive this. Meeting is tomorrow.\nUnrelated line.',
      );

      final typo = engine.search(
        document,
        const NoteSearchQuery(text: 'recieve', mode: NoteSearchMode.smart),
      );
      expect(typo.matches, hasLength(1));
      expect(
        document.text.substring(
          typo.matches.single.start,
          typo.matches.single.end,
        ),
        'receive',
      );

      final abbreviation = engine.search(
        document,
        const NoteSearchQuery(text: 'mtg tmrw', mode: NoteSearchMode.smart),
      );
      expect(abbreviation.matches, hasLength(1));
      expect(
        document.text.substring(
          abbreviation.matches.single.start,
          abbreviation.matches.single.end,
        ),
        'Meeting is tomorrow',
      );
    });

    test('deduplicates overlapping candidates and stays line-bounded', () {
      const document = NoteSearchDocument(
        text: 'meeting tomorrow meeting tomorrow\nmeeting\ntomorrow',
      );
      final result = engine.search(
        document,
        const NoteSearchQuery(text: 'mtg tmrw', mode: NoteSearchMode.smart),
      );

      expect(result.matches, hasLength(2));
      expect(
        result.matches.every(
          (match) =>
              !document.text.substring(match.start, match.end).contains('\n'),
        ),
        isTrue,
      );
    });
  });

  test('does not return matches that cross embed placeholders', () {
    final document = NoteSearchDocument.fromDeltaJson([
      {'insert': 'before '},
      {
        'insert': {'image': 'image.png'},
      },
      {'insert': ' after\n'},
    ]);

    final safe = engine.search(document, const NoteSearchQuery(text: 'before'));
    final crossing = engine.search(
      document,
      const NoteSearchQuery(
        text: r'before .* after',
        mode: NoteSearchMode.regularExpression,
      ),
    );

    expect(safe.matches, hasLength(1));
    expect(crossing.matches, isEmpty);
  });

  test('finds a late match in a large document without truncating results', () {
    final document = NoteSearchDocument(
      text: '${'common line\n' * 40000}unique-tail',
    );
    final result = engine.search(
      document,
      const NoteSearchQuery(text: 'unique-tail'),
    );

    expect(result.matches, hasLength(1));
    expect(result.matches.single.end, document.text.length);
  });
}
