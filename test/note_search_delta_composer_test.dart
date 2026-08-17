import 'package:better_keep/services/note_search_delta_composer.dart';
import 'package:better_keep/services/note_search_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const engine = NoteSearchEngine();

  test('replace all preserves surrounding rich text and embeds', () {
    final source = Delta()
      ..insert('bold', {'bold': true})
      ..insert(' plain ')
      ..insert({'image': 'image.png'})
      ..insert(' plain')
      ..insert('\n', {'list': 'bullet'});
    final document = Document.fromDelta(source);
    final searchable = NoteSearchDocument.fromDeltaJson(
      document.toDelta().toJson().cast<Map<String, dynamic>>(),
    );
    final plan = engine.buildReplacementPlan(
      document: searchable,
      query: const NoteSearchQuery(text: 'plain'),
      replacement: 'text',
    );

    final transaction = NoteSearchDeltaComposer.build(document, plan);
    document.compose(transaction, ChangeSource.local);

    expect(document.toPlainText(), 'bold text \uFFFC text\n');
    final operations = document.toDelta().toList();
    expect(operations.first.attributes, {'bold': true});
    expect(
      operations.any(
        (operation) =>
            operation.data is Map &&
            (operation.data as Map<String, dynamic>)['image'] == 'image.png',
      ),
      isTrue,
    );
    expect(operations.last.attributes, {'list': 'bullet'});
  });

  test('inserted lines inherit source block attributes', () {
    final document = Document.fromDelta(
      Delta()
        ..insert('task')
        ..insert('\n', {'list': 'checked'}),
    );
    final searchable = NoteSearchDocument.fromDeltaJson(
      document.toDelta().toJson().cast<Map<String, dynamic>>(),
    );
    final plan = engine.buildReplacementPlan(
      document: searchable,
      query: const NoteSearchQuery(text: 'task'),
      replacement: 'done\nnext',
    );

    document.compose(
      NoteSearchDeltaComposer.build(document, plan),
      ChangeSource.local,
    );

    expect(document.toPlainText(), 'done\nnext\n');
    final newlineOperations = document
        .toDelta()
        .toList()
        .where(
          (operation) =>
              operation.data is String &&
              (operation.data as String).contains('\n'),
        )
        .toList();
    expect(newlineOperations, hasLength(2));
    expect(
      newlineOperations.every(
        (operation) => operation.attributes?['list'] == 'checked',
      ),
      isTrue,
    );
  });

  test('replacement inherits the starting inline style and link', () {
    final document = Document.fromDelta(
      Delta()
        ..insert('mi', {'bold': true, 'link': 'https://example.com'})
        ..insert('xed', {'italic': true})
        ..insert('\n'),
    );
    final searchable = NoteSearchDocument.fromDeltaJson(
      document.toDelta().toJson().cast<Map<String, dynamic>>(),
    );
    final plan = engine.buildReplacementPlan(
      document: searchable,
      query: const NoteSearchQuery(text: 'mixed'),
      replacement: 'fixed',
    );

    document.compose(
      NoteSearchDeltaComposer.build(document, plan),
      ChangeSource.local,
    );

    final first = document.toDelta().toList().first;
    expect(first.data, 'fixed');
    expect(first.attributes, {'bold': true, 'link': 'https://example.com'});
  });

  test('replace all composes as one undoable controller change', () {
    final document = Document.fromDelta(Delta()..insert('one one\n'));
    final controller = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
    );
    addTearDown(controller.dispose);
    final searchable = NoteSearchDocument.fromDeltaJson(
      document.toDelta().toJson().cast<Map<String, dynamic>>(),
    );
    final plan = engine.buildReplacementPlan(
      document: searchable,
      query: const NoteSearchQuery(text: 'one'),
      replacement: 'two',
    );

    controller.compose(
      NoteSearchDeltaComposer.build(document, plan),
      const TextSelection.collapsed(offset: 3),
      ChangeSource.local,
    );
    expect(document.toPlainText(), 'two two\n');

    controller.undo();
    expect(document.toPlainText(), 'one one\n');
  });
}
