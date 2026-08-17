import 'package:better_keep/services/note_search_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

abstract final class NoteSearchHighlighter {
  static InlineSpan build({
    required Node node,
    required int nodeOffset,
    required String text,
    required TextStyle? style,
    required GestureRecognizer? recognizer,
    required List<NoteSearchMatch> matches,
    required NoteSearchMatch? activeMatch,
    required Color matchColor,
    required Color activeMatchColor,
  }) {
    if (text.isEmpty || matches.isEmpty) {
      return _span(text, style, recognizer);
    }
    final globalStart = node.documentOffset + nodeOffset;
    final globalEnd = globalStart + text.length;
    final intersections = matches.where(
      (match) => match.start < globalEnd && match.end > globalStart,
    );
    if (intersections.isEmpty) return _span(text, style, recognizer);

    final children = <InlineSpan>[];
    var cursor = 0;
    for (final match in intersections) {
      final localStart = (match.start - globalStart).clamp(0, text.length);
      final localEnd = (match.end - globalStart).clamp(0, text.length);
      if (localStart > cursor) {
        children.add(
          _span(text.substring(cursor, localStart), style, recognizer),
        );
      }
      if (localEnd > localStart) {
        final active =
            activeMatch != null &&
            activeMatch.start == match.start &&
            activeMatch.end == match.end;
        children.add(
          _span(
            text.substring(localStart, localEnd),
            style?.copyWith(
                  backgroundColor: active ? activeMatchColor : matchColor,
                ) ??
                TextStyle(
                  backgroundColor: active ? activeMatchColor : matchColor,
                ),
            recognizer,
          ),
        );
      }
      if (localEnd > cursor) cursor = localEnd;
    }
    if (cursor < text.length) {
      children.add(_span(text.substring(cursor), style, recognizer));
    }
    return TextSpan(children: children);
  }

  static TextSpan _span(
    String text,
    TextStyle? style,
    GestureRecognizer? recognizer,
  ) {
    return TextSpan(
      text: text,
      style: style,
      recognizer: recognizer,
      mouseCursor: recognizer == null ? null : SystemMouseCursors.click,
    );
  }
}
