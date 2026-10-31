import 'dart:ui' show Tristate;

import 'package:better_keep/components/quill_input_semantics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'web Quill exposes a focused multiline input and preserves rich text',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final focus = FocusNode();
      final otherFocus = FocusNode();
      final controller = QuillController(
        document: Document.fromJson([
          {
            'insert': 'Bold',
            'attributes': {'bold': true},
          },
          {'insert': '\n'},
        ]),
        selection: const TextSelection.collapsed(offset: 4),
      );
      Widget buildEditor() => MaterialApp(
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: Scaffold(
          body: Column(
            children: [
              TextButton(
                focusNode: otherFocus,
                onPressed: () {},
                child: const Text('Other field'),
              ),
              Expanded(
                child: QuillEditor.basic(
                  controller: controller,
                  focusNode: focus,
                ).withWebInputSemantics(),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(buildEditor());
      focus.requestFocus();
      await tester.pump();
      final input = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.textField == true,
      );
      if (kIsWeb) {
        expect(input, findsOneWidget);
        final node = tester.getSemantics(input);
        expect(node.flagsCollection.isTextField, true);
        expect(node.flagsCollection.isMultiline, true);
        expect(node.flagsCollection.isFocused, Tristate.isTrue);
        expect(node.value, 'Bold\n');
      } else {
        // Native Quill's input connection needs no DOM semantics adapter.
        expect(input, findsNothing);
      }
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Bold typed\n',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();
      expect(controller.document.toPlainText(), 'Bold typed\n');
      expect(controller.document.toDelta().toJson().first['attributes'], {
        'bold': true,
      });
      if (kIsWeb) {
        expect(tester.getSemantics(input).value, 'Bold typed\n');
        controller.readOnly = true;
        await tester.pumpWidget(buildEditor());
        expect(tester.getSemantics(input).flagsCollection.isReadOnly, true);
        otherFocus.requestFocus();
        await tester.pump();
        await tester.pump();
        expect(otherFocus.hasPrimaryFocus, true);
        expect(
          tester.getSemantics(input).flagsCollection.isFocused,
          Tristate.isFalse,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      controller.dispose();
      focus.dispose();
      otherFocus.dispose();
      semantics.dispose();
    },
  );
}
