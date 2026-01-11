import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Custom leading block builder that fixes ordered list numbering when
/// checkboxes or other list types are nested inside.
///
/// The default flutter_quill implementation incorrectly resets the
/// `indentLevelCounts` when it encounters a different list type (e.g., checkbox)
/// even if that item is nested (higher indent level). This causes ordered lists
/// to restart numbering after nested checkboxes.
///
/// This builder calculates the correct ordered list number by traversing
/// backwards through the document to count ordered list items at the same
/// indent level.
Widget? customLeadingBlockBuilder(Node node, LeadingConfig config) {
  // Only handle ordered lists - let others use default rendering
  if (config.attribute != Attribute.ol) {
    return null;
  }

  // Get the indent level for this line (0 if not indented)
  final indentAttr = config.attrs[Attribute.indent.key];
  final indent = (indentAttr?.value as int?) ?? 0;

  // Navigate to the document root to count all ordered list items
  // The node passed is a Line, and we need to traverse all lines in the document
  Node? root = node;
  while (root?.parent != null) {
    root = root!.parent;
  }

  // Calculate the correct number by counting ordered list items at this indent level
  // before the current node
  int number = 0;

  if (root is Root) {
    for (final child in root.children) {
      if (child is Line) {
        if (identical(child, node)) {
          number++; // Count the current node
          break;
        }

        final childAttrs = child.style.attributes;
        final childListAttr = childAttrs[Attribute.list.key];
        final childIndentAttr = childAttrs[Attribute.indent.key];
        final childIndent = (childIndentAttr?.value as int?) ?? 0;

        // If we hit a line with no list attribute at our indent level, reset
        if (childListAttr == null && childIndent <= indent) {
          number = 0;
          continue;
        }

        // If we hit an ordered list at the same indent level, increment count
        if (childListAttr == Attribute.ol && childIndent == indent) {
          number++;
        }
        // If we hit a non-ordered-list at the same indent level (bullet), reset
        else if (childListAttr != null &&
            childListAttr != Attribute.ol &&
            childListAttr != Attribute.checked &&
            childListAttr != Attribute.unchecked &&
            childIndent == indent) {
          number = 0;
        }
        // Checkboxes/bullets at higher indent (nested) - don't reset parent count
        // Just skip them
      } else if (child is Block) {
        // Traverse lines within blocks
        bool foundInBlock = false;
        for (final blockChild in child.children) {
          if (blockChild is Line) {
            if (identical(blockChild, node)) {
              number++; // Count the current node
              foundInBlock = true;
              break;
            }

            final childAttrs = blockChild.style.attributes;
            final childListAttr = childAttrs[Attribute.list.key];
            final childIndentAttr = childAttrs[Attribute.indent.key];
            final childIndent = (childIndentAttr?.value as int?) ?? 0;

            if (childListAttr == null && childIndent <= indent) {
              number = 0;
              continue;
            }

            if (childListAttr == Attribute.ol && childIndent == indent) {
              number++;
            } else if (childListAttr != null &&
                childListAttr != Attribute.ol &&
                childListAttr != Attribute.checked &&
                childListAttr != Attribute.unchecked &&
                childIndent == indent) {
              number = 0;
            }
          }
        }
        if (foundInBlock) break;
      }
    }
  }

  // Fallback if we couldn't count properly
  if (number == 0) {
    number = 1;
  }

  // Build the number point widget with our corrected number
  return QuillNumberPoint(
    index: number.toString(),
    indentLevelCounts: {indent: number},
    count: config.count,
    style: config.style ?? const TextStyle(),
    attrs: config.attrs,
    width: config.width ?? 32,
    padding: config.padding ?? 0,
    withDot: config.withDot,
  );
}

/// Builds DefaultStyles for QuillEditor with consistent theming based on colors.
///
/// This consolidates the duplicated styling logic from note_editor and note_card.
DefaultStyles buildQuillStyles({
  required Color foregroundColor,
  required Color backgroundColor,
  Color? placeholderColor,
  Color? secondaryColor,
}) {
  final defaultStyles = DefaultStyles();
  final isDarkBg = isDark(backgroundColor);
  final linkColor = isDarkBg ? Colors.lightBlueAccent : Colors.blue;
  final codeBackgroundColor = isDarkBg
      ? Colors.white.withAlpha(20)
      : Colors.black.withAlpha(15);

  return DefaultStyles(
    color: foregroundColor,
    paragraph: DefaultTextBlockStyle(
      TextStyle(fontSize: 16, color: foregroundColor),
      HorizontalSpacing.zero,
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    ),
    h1: DefaultTextBlockStyle(
      (defaultStyles.h1?.style ?? TextStyle(fontSize: 28)).copyWith(
        color: foregroundColor,
      ),
      defaultStyles.h1?.horizontalSpacing ?? HorizontalSpacing.zero,
      VerticalSpacing(0, 10),
      defaultStyles.h1?.lineSpacing ?? VerticalSpacing.zero,
      defaultStyles.h1?.decoration,
    ),
    h2: DefaultTextBlockStyle(
      (defaultStyles.h2?.style ?? TextStyle(fontSize: 24)).copyWith(
        color: foregroundColor,
      ),
      defaultStyles.h2?.horizontalSpacing ?? HorizontalSpacing.zero,
      defaultStyles.h2?.verticalSpacing ?? VerticalSpacing.zero,
      defaultStyles.h2?.lineSpacing ?? VerticalSpacing.zero,
      defaultStyles.h2?.decoration,
    ),
    h3: DefaultTextBlockStyle(
      (defaultStyles.h3?.style ?? TextStyle(fontSize: 20)).copyWith(
        color: foregroundColor,
      ),
      defaultStyles.h3?.horizontalSpacing ?? HorizontalSpacing.zero,
      defaultStyles.h3?.verticalSpacing ?? VerticalSpacing.zero,
      defaultStyles.h3?.lineSpacing ?? VerticalSpacing.zero,
      defaultStyles.h3?.decoration,
    ),
    quote: DefaultTextBlockStyle(
      TextStyle(color: secondaryColor ?? foregroundColor.withAlpha(180)),
      HorizontalSpacing.zero,
      VerticalSpacing(4, 4),
      VerticalSpacing.zero,
      BoxDecoration(
        border: Border(
          left: BorderSide(
            color: secondaryColor ?? foregroundColor.withAlpha(180),
            width: 3,
          ),
        ),
      ),
    ),
    lists: DefaultListBlockStyle(
      TextStyle(fontSize: 16, color: foregroundColor),
      HorizontalSpacing.zero,
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
      null,
    ),
    code: DefaultTextBlockStyle(
      TextStyle(fontSize: 14, color: foregroundColor, fontFamily: 'monospace'),
      HorizontalSpacing.zero,
      VerticalSpacing(4, 4),
      VerticalSpacing.zero,
      BoxDecoration(
        color: codeBackgroundColor,
        borderRadius: BorderRadius.circular(4),
      ),
    ),
    inlineCode: InlineCodeStyle(
      style: TextStyle(
        fontSize: 14,
        color: foregroundColor,
        fontFamily: 'monospace',
      ),
      backgroundColor: codeBackgroundColor,
      radius: const Radius.circular(4),
    ),
    bold: TextStyle(fontWeight: FontWeight.bold, color: foregroundColor),
    italic: TextStyle(fontStyle: FontStyle.italic, color: foregroundColor),
    underline: TextStyle(
      decoration: TextDecoration.underline,
      decorationColor: foregroundColor,
      color: foregroundColor,
    ),
    strikeThrough: TextStyle(
      decoration: TextDecoration.lineThrough,
      decorationColor: foregroundColor,
      color: foregroundColor,
    ),
    link: TextStyle(color: linkColor, decoration: TextDecoration.underline),
    placeHolder: placeholderColor != null
        ? DefaultTextBlockStyle(
            TextStyle(fontSize: 16, color: placeholderColor),
            HorizontalSpacing.zero,
            VerticalSpacing.zero,
            VerticalSpacing.zero,
            null,
          )
        : null,
  );
}
