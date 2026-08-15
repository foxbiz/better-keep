import 'dart:convert';
import 'dart:math';

import 'package:better_keep/models/rich_checklist.dart';
import 'package:better_keep/services/checklist_delta_codec.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChecklistDeltaCodec', () {
    late ChecklistDeltaCodec codec;
    var nextId = 0;

    setUp(() {
      nextId = 0;
      codec = ChecklistDeltaCodec(newId: () => 'item-${nextId++}');
    });

    test('round-trips rich inline and line attributes', () {
      final source = <Map<String, dynamic>>[
        {
          'insert': 'Large ',
          'attributes': {'size': '24', 'color': '#ff0000', 'bold': true},
        },
        {
          'insert': 'linked',
          'attributes': {
            'link': 'https://example.com',
            'underline': true,
            'custom-inline': {'future': true},
          },
        },
        {
          'insert': '\n',
          'attributes': {
            'list': 'unchecked',
            'align': 'right',
            'direction': 'rtl',
            'line-height': 1.5,
            'custom-line': 'preserve-me',
          },
        },
        {
          'insert': 'Nested',
          'attributes': {
            'italic': true,
            'strike': true,
            'background': '#00ff00',
            'script': 'super',
            'font': 'serif',
            'code': true,
          },
        },
        {
          'insert': '\n',
          'attributes': {'list': 'checked', 'indent': 1},
        },
      ];
      final document = documentFromJsonSafe(source);

      final result = codec.tryDecodeDocument(document);

      expect(result.reason, isNull);
      expect(result.document, isNotNull);
      expect(result.document!.items, hasLength(2));
      expect(result.document!.items.first.lineAttributes, {
        'align': 'right',
        'direction': 'rtl',
        'line-height': 1.5,
        'custom-line': 'preserve-me',
      });
      expect(result.document!.items.last.indent, 1);
      expect(result.document!.items.last.checked, isTrue);
      expect(
        _canonical(codec.encodeBody(result.document!)),
        _canonical(document.toDelta().toJson()),
      );
    });

    test('supports empty formatted checklist items', () {
      final result = codec.tryDecodeOperations([
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'color': '#123456', 'size': '20'},
        },
      ]);

      expect(result.isEligible, isTrue);
      expect(result.document!.items.single.isEmpty, isTrue);
      expect(result.document!.items.single.lineAttributes['color'], '#123456');
    });

    test('accepts semantically equivalent explicit zero indentation', () {
      final result = codec.tryDecodeDocument(
        documentFromJsonSafe([
          {'insert': 'Task'},
          {
            'insert': '\n',
            'attributes': {'list': 'unchecked', 'indent': 0},
          },
        ]),
      );

      expect(result.isEligible, isTrue, reason: result.reason);
      expect(result.document!.items.single.indent, 0);
    });

    test('normalizes rich multiline row paste into unchecked siblings', () {
      final original = RichChecklistItem(
        id: 'stable-id',
        inlineDelta: const [
          {
            'insert': 'Original',
            'attributes': {'bold': true},
          },
        ],
        checked: true,
        indent: 1,
        lineAttributes: const {'direction': 'rtl'},
      );
      final result = codec.tryDecodeEditedRow(
        original: original,
        document: documentFromJsonSafe([
          {
            'insert': 'First🙂',
            'attributes': {'bold': true, 'link': 'https://example.com'},
          },
          {
            'insert': '\n',
            'attributes': {'direction': 'rtl'},
          },
          {
            'insert': 'Second',
            'attributes': {'color': '#123456'},
          },
          {'insert': '\n'},
        ]),
      );

      expect(result.isEligible, isTrue, reason: result.reason);
      expect(result.document!.items, hasLength(2));
      expect(result.document!.items.first.id, 'stable-id');
      expect(result.document!.items.first.checked, isTrue);
      expect(result.document!.items.last.checked, isFalse);
      expect(result.document!.items.every((item) => item.indent == 1), isTrue);
      expect(result.document!.items.first.lineAttributes['direction'], 'rtl');
      expect(result.document!.items.first.inlineDelta.single['attributes'], {
        'bold': true,
        'link': 'https://example.com',
      });
      expect(result.document!.items.last.inlineDelta.single['attributes'], {
        'color': '#123456',
      });
    });

    test('rejects ordinary paragraphs and embeds', () {
      final paragraph = codec.tryDecodeOperations([
        {'insert': 'Paragraph\n'},
      ]);
      final embed = codec.tryDecodeOperations([
        {
          'insert': {'image': 'image.png'},
        },
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);

      expect(paragraph.isEligible, isFalse);
      expect(
        paragraph.failureReason,
        ChecklistDeltaFailureReason.nonChecklistLine,
      );
      expect(embed.isEligible, isFalse);
      expect(embed.failureReason, ChecklistDeltaFailureReason.embed);
    });

    test('rejects incompatible block formats and orphan indentation', () {
      final heading = codec.tryDecodeOperations([
        {'insert': 'Task'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'header': 2},
        },
      ]);
      final orphan = codec.tryDecodeOperations([
        {'insert': 'Task'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'indent': 2},
        },
      ]);

      expect(heading.isEligible, isFalse);
      expect(
        heading.failureReason,
        ChecklistDeltaFailureReason.incompatibleBlock,
      );
      expect(orphan.isEligible, isFalse);
      expect(
        orphan.failureReason,
        ChecklistDeltaFailureReason.orphanedIndentation,
      );
    });

    test('combined encoding preserves the note title convention', () {
      final decoded = codec.tryDecodeOperations([
        {'insert': 'Task'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);

      final combined = codec.encodeCombined(
        title: 'My list',
        document: decoded.document!,
      );

      expect(combined[0], {'insert': 'My list'});
      expect(combined[1], {
        'insert': '\n',
        'attributes': {'header': 1},
      });
      expect(
        codec.combinedPlainText(title: 'My list', document: decoded.document!),
        'My list\nTask',
      );

      final combinedDecoded = codec.tryDecodeCombinedJson(
        codec.encodeCombinedJson(title: 'My list', document: decoded.document!),
      );
      expect(
        combinedDecoded.isEligible,
        isTrue,
        reason: combinedDecoded.reason,
      );
      expect(combinedDecoded.document!.items.single.plainText, 'Task');
    });

    test('extracts independent checklist blocks from a mixed rich note', () {
      final document = documentFromJsonSafe([
        {'insert': 'Intro paragraph\n'},
        {
          'insert': 'First',
          'attributes': {'bold': true},
        },
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
        {'insert': 'Second'},
        {
          'insert': '\n',
          'attributes': {'list': 'checked'},
        },
        {'insert': 'Between\n'},
        {
          'insert': {'image': 'outside.png'},
        },
        {'insert': '\n'},
        {'insert': 'Third'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);

      final blocks = codec.scanChecklistBlocks(document);

      expect(blocks, hasLength(2));
      expect(blocks.every((block) => block.isEligible), isTrue);
      expect(blocks.first.slice!.document.items.map((item) => item.plainText), [
        'First',
        'Second',
      ]);
      expect(blocks.last.slice!.document.items.single.plainText, 'Third');
      expect(codec.findChecklistBlockAt(document, 2).isChecklistLine, isFalse);
      expect(
        codec
            .findChecklistBlockAt(document, blocks.last.startOffset!)
            .slice
            ?.identity,
        blocks.last.slice!.identity,
      );
      final session = codec.createEditSession(
        title: 'Mixed note',
        document: document,
        caretOffset: blocks.last.startOffset!,
        selectionStart: blocks.last.startOffset!,
        selectionEnd: blocks.last.startOffset!,
      );
      expect(session!.blockOrdinal, 1);
      expect(session.block.document.items.single.plainText, 'Third');
      expect(
        _canonical(session.bodyDelta),
        _canonical(document.toDelta().toJson()),
      );
    });

    test('splices only the selected block and rejects a stale source', () {
      final source = documentFromJsonSafe([
        {'insert': 'Before\n'},
        {'insert': 'Task'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
        {'insert': 'After\n'},
      ]);
      final block = codec.scanChecklistBlocks(source).single.slice!;
      final edited = RichChecklistDocument([
        block.document.items.single.copyWith(
          inlineDelta: const [
            {
              'insert': 'Edited',
              'attributes': {'color': '#123456'},
            },
          ],
        ),
      ]);

      final result = codec.replaceBlockDocument(
        bodyDelta: source.toDelta().toJson(),
        sourceBlock: block,
        document: edited,
      );

      expect(
        documentFromJsonSafe(result.bodyDelta).toPlainText(),
        'Before\nEdited\nAfter\n',
      );
      expect(result.block!.document.items.single.inlineDelta.single, {
        'insert': 'Edited',
        'attributes': {'color': '#123456'},
      });

      final staleBody = source.toDelta().toJson();
      staleBody[0] = {'insert': 'Changed before Task\n'};
      expect(
        () => codec.replaceBlockDocument(
          bodyDelta: staleBody,
          sourceBlock: block,
          document: edited,
        ),
        throwsA(isA<ChecklistBlockStaleException>()),
      );
    });

    test('normalizes and restores a non-zero block indentation baseline', () {
      final source = documentFromJsonSafe([
        {'insert': 'Nested root'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked', 'indent': 2},
        },
        {'insert': 'Nested child'},
        {
          'insert': '\n',
          'attributes': {'list': 'checked', 'indent': 3},
        },
      ]);

      final block = codec.scanChecklistBlocks(source).single.slice!;

      expect(block.baseIndent, 2);
      expect(block.document.items.map((item) => item.indent), [0, 1]);
      expect(
        _canonical(
          codec.encodeBlock(block.document, baseIndent: block.baseIndent),
        ),
        _canonical(source.toDelta().toJson()),
      );
    });

    test('rejects embeds only when they belong to the selected block', () {
      final source = documentFromJsonSafe([
        {
          'insert': {'image': 'ordinary-line.png'},
        },
        {'insert': '\n'},
        {
          'insert': {'image': 'checklist-line.png'},
        },
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);

      final block = codec.scanChecklistBlocks(source).single;

      expect(block.isEligible, isFalse);
      expect(block.failureReason, ChecklistDeltaFailureReason.embed);
      expect(codec.findChecklistBlockAt(source, 0).isChecklistLine, isFalse);
    });

    test(
      'builds contextual collection sections including unsupported blocks',
      () {
        final source = documentFromJsonSafe([
          {'insert': 'Introduction\nGroceries\n'},
          {'insert': 'Milk'},
          {
            'insert': '\n',
            'attributes': {'list': 'unchecked'},
          },
          {'insert': 'Bread'},
          {
            'insert': '\n',
            'attributes': {'list': 'checked'},
          },
          {'insert': '\nCalls\n'},
          {
            'insert': {'image': 'inside-checklist.png'},
          },
          {
            'insert': '\n',
            'attributes': {'list': 'unchecked'},
          },
        ]);

        final session = codec.createCollectionEditSession(
          title: 'Mixed',
          document: source,
          selectionStart: 0,
          selectionEnd: 0,
        )!;

        expect(session.collection.sections, hasLength(2));
        expect(session.collection.sections.first.contextLabel, 'Groceries');
        expect(session.collection.sections.first.isEligible, isTrue);
        expect(session.collection.sections.first.checkedCount, 1);
        expect(session.collection.sections.first.totalCount, 2);
        expect(session.collection.sections.last.contextLabel, 'Calls');
        expect(session.collection.sections.last.isEligible, isFalse);
        expect(
          session.collection.sections.last.failureReason,
          ChecklistDeltaFailureReason.embed,
        );
        expect(session.collection.sections.last.totalCount, 1);
        expect(session.collection.checkedCount, 1);
        expect(session.collection.totalCount, 3);
      },
    );

    test('keeps contextual labels empty when no text precedes a block', () {
      final source = documentFromJsonSafe([
        {'insert': 'First task'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
        {'insert': '\n'},
        {
          'insert': {'image': 'between.png'},
        },
        {'insert': '\n'},
        {'insert': 'Second task'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);

      final session = codec.createCollectionEditSession(
        title: 'Mixed',
        document: source,
        selectionStart: 0,
        selectionEnd: 0,
      )!;

      expect(session.collection.sections, hasLength(2));
      expect(session.collection.sections.first.contextLabel, isNull);
      expect(session.collection.sections.last.contextLabel, isNull);
    });

    test(
      'splices every edited collection block without touching separators',
      () {
        final source = documentFromJsonSafe([
          {
            'insert': 'First heading\n',
            'attributes': {'color': '#123456'},
          },
          {'insert': 'One'},
          {
            'insert': '\n',
            'attributes': {'list': 'unchecked'},
          },
          {
            'insert': {'image': 'between.png'},
          },
          {'insert': '\nSecond heading\n'},
          {'insert': 'Two'},
          {
            'insert': '\n',
            'attributes': {'list': 'checked'},
          },
          {'insert': 'Tail\n'},
        ]);
        final session = codec.createCollectionEditSession(
          title: 'Mixed',
          document: source,
          selectionStart: 0,
          selectionEnd: 0,
        )!;
        final first = session.collection.sections.first;
        final second = session.collection.sections.last;
        final edited = RichChecklistCollection([
          first.withDocument(
            RichChecklistDocument([
              first.document!.items.single.copyWith(
                inlineDelta: const [
                  {
                    'insert': 'First task expanded',
                    'attributes': {'bold': true},
                  },
                ],
              ),
            ]),
          ),
          second.withDocument(
            RichChecklistDocument([
              second.document!.items.single.copyWith(
                inlineDelta: const [
                  {
                    'insert': 'Second edited',
                    'attributes': {'link': 'https://example.com'},
                  },
                ],
              ),
            ]),
          ),
        ]);

        final result = codec.replaceCollectionDocuments(
          bodyDelta: session.bodyDelta,
          collection: edited,
        );

        expect(result.replacements, hasLength(2));
        final operations = result.bodyDelta;
        expect(
          operations.any(
            (operation) =>
                operation['insert'] is Map &&
                (operation['insert'] as Map)['image'] == 'between.png',
          ),
          isTrue,
        );
        expect(
          operations.firstWhere(
            (operation) => operation['insert'] == 'First heading\n',
          )['attributes'],
          {'color': '#123456'},
        );
        expect(
          documentFromJsonSafe(operations).toPlainText(),
          contains('First task expanded'),
        );
        expect(
          documentFromJsonSafe(operations).toPlainText(),
          contains('Second edited'),
        );

        final transaction = codec.buildCollectionTransaction(
          currentBodyDelta: session.bodyDelta,
          replacements: result.replacements,
        );
        final composed = Document.fromDelta(
          Delta.fromJson(session.bodyDelta).compose(transaction),
        );
        expect(_canonical(composed.toDelta().toJson()), _canonical(operations));
      },
    );

    test('rejects a collection splice when any source block is stale', () {
      final source = documentFromJsonSafe([
        {'insert': 'One'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
        {'insert': 'Gap\n'},
        {'insert': 'Two'},
        {
          'insert': '\n',
          'attributes': {'list': 'unchecked'},
        },
      ]);
      final session = codec.createCollectionEditSession(
        title: '',
        document: source,
        selectionStart: 0,
        selectionEnd: 0,
      )!;
      final stale = source.toDelta().toJson();
      stale[0] = {'insert': 'Changed'};

      expect(
        () => codec.replaceCollectionDocuments(
          bodyDelta: stale,
          collection: session.collection,
        ),
        throwsA(isA<ChecklistBlockStaleException>()),
      );
    });

    test('randomized eligible Deltas remain equivalent after two decodes', () {
      final random = Random(8427);
      const words = ['alpha', 'βeta', 'שלום', '🙂', 'कर्म'];
      const colors = ['#ff0000', '#00aa55', '#123456'];

      for (var sample = 0; sample < 100; sample++) {
        final operations = <Map<String, dynamic>>[];
        var previousIndent = 0;
        final lineCount = 1 + random.nextInt(12);
        for (var line = 0; line < lineCount; line++) {
          final indent = line == 0
              ? 0
              : random.nextInt(min(previousIndent + 2, 4));
          previousIndent = indent;
          final runCount = 1 + random.nextInt(3);
          for (var run = 0; run < runCount; run++) {
            final attributes = <String, dynamic>{
              if (random.nextBool()) 'bold': true,
              if (random.nextBool()) 'italic': true,
              if (random.nextInt(4) == 0) 'underline': true,
              if (random.nextInt(5) == 0) 'strike': true,
              if (random.nextInt(3) == 0)
                'color': colors[random.nextInt(colors.length)],
              if (random.nextInt(4) == 0) 'size': 12 + random.nextInt(20),
              if (random.nextInt(6) == 0) 'script': 'sub',
              if (random.nextInt(7) == 0) 'future-inline': sample,
            };
            operations.add({
              'insert': words[random.nextInt(words.length)],
              if (attributes.isNotEmpty) 'attributes': attributes,
            });
          }
          operations.add({
            'insert': '\n',
            'attributes': {
              'list': random.nextBool() ? 'checked' : 'unchecked',
              if (indent > 0) 'indent': indent,
              if (random.nextInt(3) == 0) 'align': 'right',
              if (random.nextInt(4) == 0) 'direction': 'rtl',
              if (random.nextInt(5) == 0) 'line-height': 1.5,
              if (random.nextInt(6) == 0) 'future-line': {'sample': sample},
            },
          });
        }

        final first = codec.tryDecodeDocument(documentFromJsonSafe(operations));
        expect(first.isEligible, isTrue, reason: first.reason);
        final second = codec.tryDecodeOperations(
          codec.encodeBody(first.document!),
        );
        expect(second.isEligible, isTrue, reason: second.reason);
        expect(
          _semanticSnapshot(second.document!),
          _semanticSnapshot(first.document!),
          reason: 'random sample $sample',
        );
      }
    });
  });

  group('RichChecklistDocument', () {
    RichChecklistItem item(
      String id,
      String text, {
      bool checked = false,
      int indent = 0,
      Map<String, dynamic>? attributes,
    }) {
      return RichChecklistItem(
        id: id,
        inlineDelta: [
          {'insert': text, 'attributes': ?attributes},
        ],
        checked: checked,
        indent: indent,
      );
    }

    test('toggle cascades descendants, bubbles parents, and groups roots', () {
      var document = RichChecklistDocument([
        item('a', 'Parent'),
        item('b', 'Child one', indent: 1),
        item('c', 'Child two', indent: 1),
        item('d', 'Other root'),
      ]);

      document = document.toggle('b', true);
      expect(document.itemById('a')!.checked, isFalse);
      document = document.toggle('c', true);

      expect(document.itemById('a')!.checked, isTrue);
      expect(document.items.map((entry) => entry.id), ['d', 'a', 'b', 'c']);
      document = document.toggle('a', false);
      expect(document.items.every((entry) => !entry.checked), isTrue);
    });

    test('indent and outdent move a complete subtree', () {
      var document = RichChecklistDocument([
        item('a', 'First'),
        item('b', 'Second'),
        item('c', 'Second child', indent: 1),
      ]);

      document = document.indentSubtree('b');
      expect(document.itemById('b')!.indent, 1);
      expect(document.itemById('c')!.indent, 2);

      document = document.outdentSubtree('b');
      expect(document.itemById('b')!.indent, 0);
      expect(document.itemById('c')!.indent, 1);
    });

    test('outdent keeps later siblings with their original parent', () {
      final document = RichChecklistDocument([
        item('a', 'Parent'),
        item('b', 'Promoted', indent: 1),
        item('c', 'Promoted child', indent: 2),
        item('d', 'Remaining child', indent: 1),
        item('e', 'Other root'),
      ]).outdentSubtree('b');

      expect(document.items.map((entry) => entry.id), [
        'a',
        'd',
        'b',
        'c',
        'e',
      ]);
      expect(document.itemById('d')!.indent, 1);
      expect(document.itemById('b')!.indent, 0);
      expect(document.itemById('c')!.indent, 1);
    });

    test('split preserves formatted runs on both sides', () {
      final document = RichChecklistDocument([
        RichChecklistItem(
          id: 'a',
          inlineDelta: const [
            {
              'insert': 'Bold',
              'attributes': {'bold': true},
            },
            {
              'insert': 'Color',
              'attributes': {'color': '#ff0000'},
            },
          ],
          checked: true,
          indent: 0,
        ),
      ]).splitItem(id: 'a', offset: 4, newId: () => 'b');

      expect(document.items, hasLength(2));
      expect(document.items.first.plainText, 'Bold');
      expect(document.items.last.plainText, 'Color');
      expect(document.items.first.inlineDelta.single['attributes'], {
        'bold': true,
      });
      expect(document.items.last.inlineDelta.single['attributes'], {
        'color': '#ff0000',
      });
      expect(document.items.last.checked, isFalse);
    });

    test('merge preserves both rich formatting boundaries and descendants', () {
      final document = RichChecklistDocument([
        item('a', 'Bold', attributes: const {'bold': true}),
        item('b', 'Color', attributes: const {'color': '#ff0000'}),
        item('c', 'Child', indent: 1),
      ]).mergeWithPrevious('b');

      expect(document.items.map((entry) => entry.id), ['a', 'c']);
      expect(document.items.first.plainText, 'BoldColor');
      expect(document.items.first.inlineDelta, [
        {
          'insert': 'Bold',
          'attributes': {'bold': true},
        },
        {
          'insert': 'Color',
          'attributes': {'color': '#ff0000'},
        },
      ]);
      expect(document.items.last.indent, 1);
    });

    test('drag and delete operate on the complete subtree', () {
      var nextId = 0;
      var document = RichChecklistDocument([
        item('a', 'A'),
        item('b', 'B'),
        item('c', 'B child', indent: 1),
        item('d', 'D'),
      ]);

      document = document.moveSubtreeBefore(id: 'b', targetId: 'a');
      expect(document.items.map((entry) => entry.id), ['b', 'c', 'a', 'd']);

      document = document.deleteSubtree('b', newId: () => 'new-${nextId++}');
      expect(document.items.map((entry) => entry.id), ['a', 'd']);
    });

    test('does not delete the sole remaining item', () {
      final document = RichChecklistDocument([
        item('only', '', attributes: const {'bold': true}),
      ]);

      final updated = document.deleteSubtree('only', newId: () => 'new');

      expect(updated.items.single.id, 'only');
      expect(
        updated.items.single.inlineDelta,
        document.items.single.inlineDelta,
      );
    });

    test(
      'clear completed keeps active roots and supplies an empty fallback',
      () {
        var nextId = 0;
        var document = RichChecklistDocument([
          item('a', 'Done', checked: true),
          item('b', 'Done child', checked: true, indent: 1),
          item('c', 'Active'),
        ]).clearCompleted(newId: () => 'new-${nextId++}');

        expect(document.items.map((entry) => entry.id), ['c']);

        document = RichChecklistDocument([
          item('a', 'Done', checked: true),
        ]).clearCompleted(newId: () => 'new-${nextId++}');
        expect(document.items.single.id, 'new-0');
        expect(document.items.single.isEmpty, isTrue);
      },
    );
  });

  group('ChecklistHistoryController', () {
    RichChecklistDocument document(String text) => RichChecklistDocument([
      RichChecklistItem(
        id: 'item',
        inlineDelta: [
          {'insert': text},
        ],
        checked: false,
        indent: 0,
      ),
    ]);

    test('coalesces typing while retaining structural undo steps', () {
      final history = ChecklistHistoryController(document(''));
      final start = DateTime(2026);
      history.commit(document('a'), coalesceKey: 'typing:item', now: start);
      history.commit(
        document('ab'),
        coalesceKey: 'typing:item',
        now: start.add(const Duration(milliseconds: 200)),
      );
      history.commit(document('abc'));

      expect(history.undo()!.document.items.single.plainText, 'ab');
      expect(history.undo()!.document.items.single.plainText, '');
      expect(history.redo()!.document.items.single.plainText, 'ab');
    });

    test('selection-only updates do not add undo entries', () {
      final initial = document('task');
      final history = ChecklistHistoryController(initial);

      history.commit(
        initial,
        selection: const ChecklistHistorySelection(
          itemId: 'item',
          baseOffset: 2,
          extentOffset: 2,
        ),
      );

      expect(history.canUndo, isFalse);
      expect(history.current.selection?.baseOffset, 2);
    });
  });

  group('ChecklistCollectionHistoryController', () {
    test('undo crosses sections and restores the section selection', () {
      RichChecklistSection section(String id, String itemId, String text) {
        final document = RichChecklistDocument([
          RichChecklistItem(
            id: itemId,
            inlineDelta: [
              {'insert': text},
            ],
            checked: false,
            indent: 0,
          ),
        ]);
        final block = ChecklistBlockSlice(
          startOffset: id == 'one' ? 0 : 5,
          endOffset: id == 'one' ? 4 : 9,
          baseIndent: 0,
          sourceDelta: [
            {'insert': text},
            {
              'insert': '\n',
              'attributes': {'list': 'unchecked'},
            },
          ],
          sourceFingerprint: id,
          document: document,
        );
        return RichChecklistSection(
          id: id,
          ordinal: id == 'one' ? 0 : 1,
          startOffset: block.startOffset,
          endOffset: block.endOffset,
          sourceDelta: block.sourceDelta,
          sourceFingerprint: block.sourceFingerprint,
          block: block,
          document: document,
          checkedCount: 0,
          totalCount: 1,
        );
      }

      final first = section('one', 'a', 'A');
      final second = section('two', 'b', 'B');
      final initial = RichChecklistCollection([first, second]);
      final history = ChecklistCollectionHistoryController(initial);
      history.commit(
        initial.replaceDocument('one', first.document!.toggle('a', true)),
        selection: const ChecklistCollectionHistorySelection(
          sectionId: 'one',
          itemId: 'a',
        ),
      );
      history.commit(
        history.current.collection.replaceDocument(
          'two',
          second.document!.toggle('b', true),
        ),
        selection: const ChecklistCollectionHistorySelection(
          sectionId: 'two',
          itemId: 'b',
        ),
      );

      final undo = history.undo()!;
      expect(undo.selection?.sectionId, 'one');
      expect(undo.collection.sectionById('one')!.checkedCount, 1);
      expect(undo.collection.sectionById('two')!.checkedCount, 0);
    });
  });
}

Object _semanticSnapshot(RichChecklistDocument document) => document.items
    .map(
      (item) => {
        'inlineDelta': item.inlineDelta,
        'checked': item.checked,
        'indent': item.indent,
        'lineAttributes': item.lineAttributes,
      },
    )
    .toList(growable: false);

String _canonical(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonicalize(value[key])};
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}
