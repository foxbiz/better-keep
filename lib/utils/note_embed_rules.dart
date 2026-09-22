import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/internal.dart' show DeleteRule, InsertRule;
import 'package:flutter_quill/quill_delta.dart';

bool isNoteBlock(Object? data) =>
    data is Map &&
    (isNoteTable(data) ||
        (data['note-attachment'] is Map &&
            (data['note-attachment'] as Map)['placement'] != 'inline'));

Object? _at(Document document, int offset) {
  if (offset < 0 || offset >= document.length) return null;
  return document.toDelta().slice(offset, offset + 1).first.data;
}

/// Text typed at a block's boundary belongs to a neighboring paragraph.
class InsertAroundNoteBlockRule extends InsertRule {
  const InsertAroundNoteBlockRule();
  @override
  Delta? applyRule(
    Document document,
    int index, {
    int? len,
    Object? data,
    Attribute? attribute,
  }) {
    if (data is! String || data.isEmpty) return null;
    final insertion = index + (len ?? 0);
    final afterBlock =
        isNoteBlock(_at(document, index - 1)) && !data.startsWith('\n');
    final beforeBlock =
        isNoteBlock(_at(document, insertion)) && !data.endsWith('\n');
    if (!afterBlock && !beforeBlock) return null;
    return Delta()
      ..retain(insertion)
      ..insert('${afterBlock ? '\n' : ''}$data${beforeBlock ? '\n' : ''}');
  }
}

/// Keep one separator when a deletion would join text onto a surviving block.
/// Deleting the block itself, or selecting it with surrounding text, still works.
class PreserveNoteBlockLineRule extends DeleteRule {
  const PreserveNoteBlockLineRule();
  @override
  Delta? applyRule(
    Document document,
    int index, {
    int? len,
    Object? data,
    Attribute? attribute,
  }) {
    if (len == null || len < 1) return null;
    final end = index + len;
    final keepFirst =
        isNoteBlock(_at(document, index - 1)) && _at(document, index) == '\n';
    final keepLast =
        isNoteBlock(_at(document, end)) &&
        index > 0 &&
        _at(document, index - 1) != '\n' &&
        _at(document, end - 1) == '\n';
    if (!keepFirst && !keepLast) return null;
    final keep = keepFirst && keepLast && len > 1 ? 2 : 1;
    return Delta()
      ..retain(index + (keepFirst ? 1 : 0))
      ..delete(len - keep);
  }
}

bool isNoteTable(Object? data) => data is Map && data.containsKey('note-table');

/// Tables and block images occupy their own line, including pasted content.
Delta normalizeNoteBlocks(Delta source) {
  if (!source.toList().any((op) => isNoteBlock(op.data))) return source;
  final result = Delta();
  var lineStart = true;
  var afterBlock = false;
  for (final op in source.toList()) {
    final data = op.data;
    if (isNoteBlock(data)) {
      if (!lineStart) result.insert('\n');
      result.push(op);
      lineStart = false;
      afterBlock = true;
    } else {
      if (afterBlock && !(data is String && data.startsWith('\n'))) {
        result.insert('\n');
      }
      result.push(op);
      lineStart = data is String && data.endsWith('\n');
      afterBlock = false;
    }
  }
  if (afterBlock) result.insert('\n');
  return result;
}

/// Quill's built-in embed insertion rule only isolates video embeds.
class InsertNoteBlockRule extends InsertRule {
  const InsertNoteBlockRule();
  @override
  Delta? applyRule(
    Document document,
    int index, {
    int? len,
    Object? data,
    Attribute? attribute,
  }) {
    if (!isNoteBlock(data)) return null;
    final end = index + (len ?? 0);
    final delta = Delta()..retain(end);
    if (index > 0 && _at(document, index - 1) != '\n') delta.insert('\n');
    delta.insert(data);
    if (_at(document, end) != '\n') delta.insert('\n');
    return delta;
  }
}
