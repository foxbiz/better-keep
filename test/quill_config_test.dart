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
