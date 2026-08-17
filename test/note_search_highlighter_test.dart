import 'package:better_keep/pages/note_editor/note_search_highlighter.dart';
import 'package:better_keep/services/note_search_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('highlight spans preserve leaf styling and link recognizers', () {
    final document = Document.fromDelta(
      Delta()
        ..insert('prefix ')
        ..insert('target', {'link': 'https://example.com'})
        ..insert('\n'),
    );
    final line = document.root.children.first as Line;
    final node = line.children.elementAt(1);
    final recognizer = TapGestureRecognizer();
    addTearDown(recognizer.dispose);
    const style = TextStyle(
      color: Colors.blue,
      decoration: TextDecoration.underline,
    );

    final span =
        NoteSearchHighlighter.build(
              node: node,
              nodeOffset: 0,
              text: 'target',
              style: style,
              recognizer: recognizer,
              matches: const [NoteSearchMatch(start: 7, end: 13)],
              activeMatch: const NoteSearchMatch(start: 7, end: 13),
              matchColor: Colors.yellow,
              activeMatchColor: Colors.orange,
            )
            as TextSpan;
    final highlighted = span.children!.single as TextSpan;

    expect(highlighted.text, 'target');
    expect(highlighted.style?.color, Colors.blue);
    expect(highlighted.style?.decoration, TextDecoration.underline);
    expect(highlighted.style?.backgroundColor, Colors.orange);
    expect(highlighted.recognizer, same(recognizer));
  });
}
