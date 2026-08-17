import 'package:better_keep/services/note_search_service.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

abstract final class NoteSearchDeltaComposer {
  static Delta build(Document document, NoteSearchReplacementPlan plan) {
    if (!plan.isValid || plan.edits.isEmpty) return Delta();
    final source = document.toDelta();
    final edits = [...plan.edits]..sort((a, b) => a.start.compareTo(b.start));
    final transaction = Delta();
    var cursor = 0;

    for (final edit in edits) {
      if (edit.start < cursor || edit.end > document.length - 1) {
        throw ArgumentError('Search replacement ranges overlap or are stale.');
      }
      final retained = edit.start - cursor;
      if (retained > 0) transaction.retain(retained);

      final inlineAttributes = _inlineAttributesAt(source, edit.start);
      final blockAttributes = _blockAttributesAt(source, edit.start);
      if (edit.replacedLength > 0) {
        transaction.delete(edit.replacedLength);
      }
      _insertReplacement(
        transaction,
        edit.replacement,
        inlineAttributes: inlineAttributes,
        blockAttributes: blockAttributes,
      );
      cursor = edit.end;
    }
    return transaction;
  }

  static Map<String, dynamic>? _inlineAttributesAt(Delta source, int offset) {
    Map<String, dynamic>? previousInline;
    var cursor = 0;
    for (final operation in source.toList()) {
      if (!operation.isInsert) continue;
      final length = operation.length ?? 0;
      final data = operation.data;
      final attributes = operation.attributes;
      if (data is String && data.isNotEmpty && !data.startsWith('\n')) {
        final inline = _filterAttributes(attributes, inline: true);
        if (inline != null) previousInline = inline;
      }
      if (offset >= cursor && offset < cursor + length) {
        if (data is String && data[offset - cursor] != '\n') {
          return _filterAttributes(attributes, inline: true);
        }
        return previousInline;
      }
      cursor += length;
    }
    return previousInline;
  }

  static Map<String, dynamic>? _blockAttributesAt(Delta source, int offset) {
    var cursor = 0;
    for (final operation in source.toList()) {
      if (!operation.isInsert) continue;
      final data = operation.data;
      final length = operation.length ?? 0;
      if (data is String) {
        final localStart = (offset - cursor).clamp(0, data.length);
        final newline = data.indexOf('\n', localStart);
        if (newline >= 0) {
          return _filterAttributes(operation.attributes, inline: false);
        }
      }
      cursor += length;
    }
    return null;
  }

  static Map<String, dynamic>? _filterAttributes(
    Map<String, dynamic>? source, {
    required bool inline,
  }) {
    if (source == null || source.isEmpty) return null;
    final result = <String, dynamic>{};
    for (final entry in source.entries) {
      final isInline = Attribute.inlineKeys.contains(entry.key);
      if (isInline == inline) result[entry.key] = entry.value;
    }
    return result.isEmpty ? null : result;
  }

  static void _insertReplacement(
    Delta transaction,
    String replacement, {
    required Map<String, dynamic>? inlineAttributes,
    required Map<String, dynamic>? blockAttributes,
  }) {
    if (replacement.isEmpty) return;
    var start = 0;
    while (start < replacement.length) {
      final newline = replacement.indexOf('\n', start);
      if (newline < 0) {
        transaction.insert(replacement.substring(start), inlineAttributes);
        return;
      }
      if (newline > start) {
        transaction.insert(
          replacement.substring(start, newline),
          inlineAttributes,
        );
      }
      transaction.insert('\n', blockAttributes);
      start = newline + 1;
    }
  }
}
