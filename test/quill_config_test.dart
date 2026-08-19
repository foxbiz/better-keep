import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/utils/quill_config.dart';

void main() {
  group('buildQuillStyles', () {
    test('returns correct foreground color for dark background', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
      );

      expect(styles.color, Colors.white);
      expect(styles.paragraph?.style.color, Colors.white);
      expect(styles.bold?.color, Colors.white);
      expect(styles.italic?.color, Colors.white);
    });

    test('returns correct foreground color for light background', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.black,
        backgroundColor: Colors.white,
      );

      expect(styles.color, Colors.black);
      expect(styles.paragraph?.style.color, Colors.black);
      expect(styles.bold?.color, Colors.black);
    });

    test('returns correct link color for dark background', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
      );

      expect(styles.link?.color, Colors.lightBlueAccent);
    });

    test('returns correct link color for light background', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.black,
        backgroundColor: Colors.white,
      );

      expect(styles.link?.color, Colors.blue);
    });

    test('includes placeholder style when placeholderColor provided', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.black,
        backgroundColor: Colors.white,
        placeholderColor: Colors.grey,
      );

      expect(styles.placeHolder, isNotNull);
      expect(styles.placeHolder?.style.color, Colors.grey);
    });

    test('includes secondary color for quote style', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.black,
        backgroundColor: Colors.white,
        secondaryColor: Colors.grey,
      );

      expect(styles.quote?.style.color, Colors.grey);
    });

    test('includes lists style', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.black,
        backgroundColor: Colors.white,
      );

      expect(styles.lists, isNotNull);
      expect(styles.lists?.style.color, Colors.black);
      expect(styles.lists?.style.height, isNull);
      expect(styles.lists?.lineSpacing.top, 0);
      expect(styles.lists?.lineSpacing.bottom, 0);
    });

    test('supports comfortable list readability without changing defaults', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.black,
        backgroundColor: Colors.white,
        comfortableLists: true,
      );

      expect(styles.lists?.style.height, 1.25);
      expect(styles.lists?.verticalSpacing.top, 0);
      expect(styles.lists?.verticalSpacing.bottom, 0);
      expect(styles.lists?.lineSpacing.top, 0);
      expect(styles.lists?.lineSpacing.bottom, 6);
    });

    test('indented paragraphs do not inherit Flutter Quill spacing', () {
      final styles = buildQuillStyles(
        foregroundColor: Colors.black,
        backgroundColor: Colors.white,
        comfortableLists: true,
      );

      expect(styles.indent, same(styles.paragraph));
      expect(styles.indent?.verticalSpacing, VerticalSpacing.zero);
      expect(styles.indent?.lineSpacing, VerticalSpacing.zero);
      expect(styles.lists?.style.height, 1.25);
      expect(styles.lists?.lineSpacing.bottom, 6);
    });

    test('includes code style with correct background', () {
      final darkStyles = buildQuillStyles(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black,
      );
      final lightStyles = buildQuillStyles(
        foregroundColor: Colors.black,
        backgroundColor: Colors.white,
      );

      expect(darkStyles.code?.decoration?.color, Colors.white.withAlpha(20));
      expect(lightStyles.code?.decoration?.color, Colors.black.withAlpha(15));
    });
  });

  group('customLeadingBlockBuilder', () {
    test('returns null for bullet list (uses default rendering)', () {
      final config = _createLeadingConfig(Attribute.ul, 1);
      final result = customLeadingBlockBuilder(_createNode(), config);

      expect(result, isNull);
    });

    test('returns null for checked checkbox (uses default rendering)', () {
      final config = _createLeadingConfig(Attribute.checked, 1);
      final result = customLeadingBlockBuilder(_createNode(), config);

      expect(result, isNull);
    });

    test('returns null for unchecked checkbox (uses default rendering)', () {
      final config = _createLeadingConfig(Attribute.unchecked, 1);
      final result = customLeadingBlockBuilder(_createNode(), config);

      expect(result, isNull);
    });

    test('returns QuillNumberPoint for ordered list', () {
      final config = _createLeadingConfig(Attribute.ol, 1);
      final result = customLeadingBlockBuilder(_createNode(), config);

      expect(result, isA<QuillNumberPoint>());
    });
  });

  group('ResetHeadingOnNewEmptyLineRule', () {
    late Document document;

    setUp(() {
      // Create a document with a heading line
      document = Document();
      document.setCustomRules(customQuillRules);
    });

    test('returns null when data is not a newline', () {
      const rule = ResetHeadingOnNewEmptyLineRule();

      final result = rule.applyRule(document, 0, data: 'hello');

      expect(result, isNull);
    });

    test('returns null when not at line start', () {
      // Create document with some text: "hello\n" with h1
      document = Document.fromJson([
        {'insert': 'hello'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
      ]);
      document.setCustomRules(customQuillRules);

      const rule = ResetHeadingOnNewEmptyLineRule();

      // Inserting in middle of line (index 2 = after "he")
      final result = rule.applyRule(document, 2, data: '\n');

      expect(result, isNull);
    });

    test('returns delta that resets heading on original content', () {
      // Create document with h1 heading: "My Heading\n"
      document = Document.fromJson([
        {'insert': 'My Heading'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
      ]);
      document.setCustomRules(customQuillRules);

      const rule = ResetHeadingOnNewEmptyLineRule();

      // Inserting at very beginning (index 0)
      final result = rule.applyRule(document, 0, data: '\n');

      expect(result, isNotNull);
      // Should:
      // 1. Insert newline WITH heading (new empty line gets heading)
      // 2. Retain to the original newline
      // 3. Reset heading on the original newline
      final ops = result!.toList();
      expect(ops.length, greaterThanOrEqualTo(2));

      // First op should insert newline with heading
      expect(ops[0].isInsert, isTrue);
      expect(ops[0].data, '\n');
      expect(ops[0].attributes, containsPair('header', 1));
    });

    test(
      'returns delta that resets heading when at start of second heading line',
      () {
        // Create document:
        // Line 1: "First line\n" (plain)
        // Line 2: "Heading line\n" (h1)
        document = Document.fromJson([
          {'insert': 'First line\n'},
          {'insert': 'Heading line'},
          {
            'insert': '\n',
            'attributes': {'header': 1},
          },
        ]);
        document.setCustomRules(customQuillRules);

        const rule = ResetHeadingOnNewEmptyLineRule();

        // Insert at start of second line (after "First line\n" = index 11)
        final result = rule.applyRule(document, 11, data: '\n');

        expect(result, isNotNull);
        final ops = result!.toList();

        // Should have: retain(11), insert('\n', {header: 1}), retain(12), retain(1, {header: null})
        expect(ops.length, greaterThanOrEqualTo(3));

        // First op: retain to position
        expect(ops[0].isRetain, isTrue);
        expect(ops[0].length, 11);

        // Second op: insert newline with heading
        expect(ops[1].isInsert, isTrue);
        expect(ops[1].data, '\n');
        expect(ops[1].attributes, containsPair('header', 1));
      },
    );

    test('returns null when inserting at start of non-heading line', () {
      // Create document with plain text line
      document = Document.fromJson([
        {'insert': 'Plain text\n'},
      ]);
      document.setCustomRules(customQuillRules);

      const rule = ResetHeadingOnNewEmptyLineRule();

      // Inserting at very beginning (index 0)
      final result = rule.applyRule(document, 0, data: '\n');

      expect(result, isNull);
    });

    test(
      'integration: inserting newline before heading resets original to plain text',
      () {
        // Create document with h1 heading
        document = Document.fromJson([
          {'insert': 'Title'},
          {
            'insert': '\n',
            'attributes': {'header': 1},
          },
        ]);
        document.setCustomRules(customQuillRules);

        // Simulate inserting at start of document
        document.insert(0, '\n');

        // Get the resulting plain text - should now have newline before Title
        final plainText = document.toPlainText();
        expect(plainText, '\nTitle\n');

        // Get the resulting delta
        final delta = document.toDelta();
        final ops = delta.toList();

        // After the rule:
        // - First line is empty with heading (but empty so visually ignored)
        // - Second line is "Title" with NO heading (reset to plain text)
        //
        // Expected delta structure:
        // [insert: '\n' with header:1], [insert: 'Title'], [insert: '\n' without header]

        // Find heading attributes
        bool firstNewlineHasHeader = false;
        bool secondNewlineHasHeader = false;
        int newlineIndex = 0;

        for (final op in ops) {
          if (op.data is String) {
            final data = op.data as String;
            for (int i = 0; i < data.length; i++) {
              if (data[i] == '\n') {
                newlineIndex++;
                final hasHeader =
                    op.attributes?.containsKey('header') == true &&
                    op.attributes!['header'] != null;
                if (newlineIndex == 1) {
                  firstNewlineHasHeader = hasHeader;
                } else if (newlineIndex == 2) {
                  secondNewlineHasHeader = hasHeader;
                }
              }
            }
          }
        }

        // First newline (empty line) should have heading
        expect(
          firstNewlineHasHeader,
          isTrue,
          reason: 'First newline (empty line) should have heading attribute',
        );

        // Second newline (after "Title") should NOT have heading - it was reset
        expect(
          secondNewlineHasHeader,
          isFalse,
          reason:
              'Second newline (Title line) should NOT have heading attribute',
        );

        // Check that Title is still present
        expect(plainText.contains('Title'), isTrue);
      },
    );

    test('integration: inserting newline after heading preserves behavior', () {
      // Create document with h1 heading followed by plain text
      document = Document.fromJson([
        {'insert': 'Title'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
        {'insert': 'Body text\n'},
      ]);
      document.setCustomRules(customQuillRules);

      // Insert at end of heading line (after "Title", before the \n)
      // "Title" is 5 chars, so insert at index 5
      document.insert(5, '\n');

      // Get the resulting delta
      final delta = document.toDelta();
      final ops = delta.toList();

      // The document should now have:
      // "Title\n" (h1) + "\n" (new, will be h1 due to default behavior) + "Body text\n"
      // Note: This test verifies the default behavior isn't broken
      expect(ops.length, greaterThanOrEqualTo(3));
    });
  });
}

/// Helper to create a mock Node for testing
Node _createNode() {
  return Line();
}

/// Helper to create LeadingConfig for testing
LeadingConfig _createLeadingConfig(Attribute attribute, int index) {
  return LeadingConfig(
    attribute: attribute,
    indentLevelCounts: {0: index},
    count: index,
    style: const TextStyle(),
    width: 32,
    padding: 0,
    value: false,
    onCheckboxTap: (_) {},
    index: index,
    attrs: {attribute.key: attribute},
    withDot: true,
    enabled: true,
    lineSize: 16,
    uiBuilder: null,
  );
}
