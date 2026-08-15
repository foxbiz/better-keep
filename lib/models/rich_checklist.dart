import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/quill_delta.dart';

typedef ChecklistItemIdFactory = String Function();

enum ChecklistDeltaFailureReason {
  empty,
  notDelta,
  malformed,
  invalidOperation,
  embed,
  textBlockAttributes,
  nonChecklistLine,
  incompatibleBlock,
  invalidIndentation,
  unterminatedLine,
  noItems,
  orphanedIndentation,
  roundTripMismatch,
}

@immutable
class RichChecklistItem {
  RichChecklistItem({
    required this.id,
    required List<Map<String, dynamic>> inlineDelta,
    required this.checked,
    required this.indent,
    Map<String, dynamic> lineAttributes = const {},
  }) : assert(indent >= 0),
       inlineDelta = List.unmodifiable(_deepCopyOperations(inlineDelta)),
       lineAttributes = Map.unmodifiable(_deepCopyMap(lineAttributes));

  final String id;
  final List<Map<String, dynamic>> inlineDelta;
  final bool checked;
  final int indent;
  final Map<String, dynamic> lineAttributes;

  Delta get delta => Delta.fromJson(_deepCopyOperations(inlineDelta));

  int get textLength => delta.toList().fold<int>(
    0,
    (length, operation) => length + (operation.length ?? 0),
  );

  String get plainText {
    final buffer = StringBuffer();
    for (final operation in delta.toList()) {
      final data = operation.data;
      if (operation.isInsert && data is String) buffer.write(data);
    }
    return buffer.toString();
  }

  bool get isEmpty => textLength == 0;

  RichChecklistItem copyWith({
    String? id,
    List<Map<String, dynamic>>? inlineDelta,
    bool? checked,
    int? indent,
    Map<String, dynamic>? lineAttributes,
  }) {
    return RichChecklistItem(
      id: id ?? this.id,
      inlineDelta: inlineDelta ?? this.inlineDelta,
      checked: checked ?? this.checked,
      indent: indent ?? this.indent,
      lineAttributes: lineAttributes ?? this.lineAttributes,
    );
  }

  Map<String, dynamic> toSnapshotJson() => {
    'id': id,
    'inlineDelta': _deepCopyOperations(inlineDelta),
    'checked': checked,
    'indent': indent,
    'lineAttributes': _deepCopyMap(lineAttributes),
  };

  factory RichChecklistItem.fromSnapshotJson(Map<String, dynamic> json) {
    return RichChecklistItem(
      id: json['id'] as String,
      inlineDelta: (json['inlineDelta'] as List)
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(),
      checked: json['checked'] as bool,
      indent: json['indent'] as int,
      lineAttributes: Map<String, dynamic>.from(
        json['lineAttributes'] as Map? ?? const {},
      ),
    );
  }
}

@immutable
class RichChecklistDocument {
  RichChecklistDocument(Iterable<RichChecklistItem> items)
    : items = List.unmodifiable(items) {
    if (this.items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'Checklist cannot be empty');
    }
  }

  final List<RichChecklistItem> items;

  RichChecklistItem? itemById(String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  int indexOfId(String id) => items.indexWhere((item) => item.id == id);

  RichChecklistItem? previousSiblingOf(String id) {
    final index = indexOfId(id);
    if (index < 0) return null;
    final previousIndex = _previousSiblingIndex(index);
    return previousIndex < 0 ? null : items[previousIndex];
  }

  int subtreeEnd(int index) {
    if (index < 0 || index >= items.length) return index;
    final indent = items[index].indent;
    var end = index + 1;
    while (end < items.length && items[end].indent > indent) {
      end++;
    }
    return end;
  }

  List<Map<String, dynamic>> toSnapshotJson() =>
      items.map((item) => item.toSnapshotJson()).toList(growable: false);

  factory RichChecklistDocument.fromSnapshotJson(List<dynamic> json) {
    return RichChecklistDocument(
      json.map(
        (entry) => RichChecklistItem.fromSnapshotJson(
          Map<String, dynamic>.from(entry as Map),
        ),
      ),
    );
  }

  RichChecklistDocument replaceItem(RichChecklistItem replacement) {
    final index = indexOfId(replacement.id);
    if (index < 0) return this;
    final updated = [...items]..[index] = replacement;
    return RichChecklistDocument(updated);
  }

  RichChecklistDocument toggle(String id, bool checked) {
    final index = indexOfId(id);
    if (index < 0) return this;

    final updated = [...items];
    final end = subtreeEnd(index);
    for (var child = index; child < end; child++) {
      updated[child] = updated[child].copyWith(checked: checked);
    }

    var parentIndent = updated[index].indent - 1;
    var searchIndex = index - 1;
    while (parentIndent >= 0) {
      var parentIndex = -1;
      for (var candidate = searchIndex; candidate >= 0; candidate--) {
        if (updated[candidate].indent == parentIndent) {
          parentIndex = candidate;
          break;
        }
      }
      if (parentIndex < 0) break;

      final parentEnd = _subtreeEndFor(updated, parentIndex);
      final directChildren = <RichChecklistItem>[];
      for (var child = parentIndex + 1; child < parentEnd; child++) {
        if (updated[child].indent == parentIndent + 1) {
          directChildren.add(updated[child]);
        }
      }
      if (directChildren.isNotEmpty) {
        updated[parentIndex] = updated[parentIndex].copyWith(
          checked: directChildren.every((child) => child.checked),
        );
      }
      searchIndex = parentIndex - 1;
      parentIndent--;
    }

    return RichChecklistDocument(updated)._activeRootsFirst();
  }

  RichChecklistDocument indentSubtree(String id) {
    final index = indexOfId(id);
    if (index <= 0) return this;
    final itemIndent = items[index].indent;
    final previousIndex = _previousSiblingIndex(index);
    if (previousIndex < 0 || items[previousIndex].indent != itemIndent) {
      return this;
    }
    return _shiftSubtree(index, 1);
  }

  RichChecklistDocument outdentSubtree(String id) {
    final index = indexOfId(id);
    if (index < 0 || items[index].indent == 0) return this;
    final end = subtreeEnd(index);
    final parentIndex = _parentIndex(index);
    if (parentIndex < 0) return this;
    final parentEnd = subtreeEnd(parentIndex);

    // Promote after the old parent's remaining descendants. Shifting the
    // subtree in place would silently adopt its following siblings.
    if (end < parentEnd) {
      final moving = items
          .sublist(index, end)
          .map((item) => item.copyWith(indent: item.indent - 1))
          .toList(growable: false);
      final updated = [...items]..removeRange(index, end);
      updated.insertAll(parentEnd - moving.length, moving);
      return RichChecklistDocument(
        updated,
      )._reconcileParentCompletion()._activeRootsFirst();
    }
    return _shiftSubtree(index, -1);
  }

  RichChecklistDocument deleteSubtree(
    String id, {
    required ChecklistItemIdFactory newId,
  }) {
    final index = indexOfId(id);
    if (index < 0) return this;
    if (items.length == 1) return this;
    final end = subtreeEnd(index);
    final updated = [...items]..removeRange(index, end);
    if (updated.isEmpty) {
      updated.add(
        RichChecklistItem(
          id: newId(),
          inlineDelta: const [],
          checked: false,
          indent: 0,
          lineAttributes: items[index].lineAttributes,
        ),
      );
    }
    return RichChecklistDocument(
      updated,
    )._reconcileParentCompletion()._activeRootsFirst();
  }

  RichChecklistDocument clearCompleted({
    required ChecklistItemIdFactory newId,
  }) {
    final updated = <RichChecklistItem>[];
    var index = 0;
    while (index < items.length) {
      final end = subtreeEnd(index);
      if (!items[index].checked) {
        updated.addAll(items.sublist(index, end));
      }
      index = end;
    }
    if (updated.isEmpty) {
      updated.add(
        RichChecklistItem(
          id: newId(),
          inlineDelta: const [],
          checked: false,
          indent: 0,
        ),
      );
    }
    return RichChecklistDocument(updated);
  }

  RichChecklistDocument splitItem({
    required String id,
    required int offset,
    required ChecklistItemIdFactory newId,
  }) {
    final index = indexOfId(id);
    if (index < 0) return this;
    final item = items[index];
    final safeOffset = offset.clamp(0, item.textLength);
    final left = item.delta.slice(0, safeOffset);
    final right = item.delta.slice(safeOffset);
    final end = subtreeEnd(index);
    final updated = [...items];
    updated[index] = item.copyWith(inlineDelta: left.toJson());
    updated.insert(
      end,
      RichChecklistItem(
        id: newId(),
        inlineDelta: right.toJson(),
        checked: false,
        indent: item.indent,
        lineAttributes: item.lineAttributes,
      ),
    );
    return RichChecklistDocument(updated);
  }

  RichChecklistDocument mergeWithPrevious(String id) {
    final index = indexOfId(id);
    if (index < 0) return this;
    final previousIndex = _previousSiblingIndex(index);
    if (previousIndex < 0) return this;

    final previous = items[previousIndex];
    final current = items[index];
    final merged = Delta();
    for (final operation in previous.delta.toList()) {
      merged.push(operation);
    }
    for (final operation in current.delta.toList()) {
      merged.push(operation);
    }
    final updated = [...items]
      ..[previousIndex] = previous.copyWith(inlineDelta: merged.toJson())
      ..removeAt(index);
    return RichChecklistDocument(
      updated,
    )._reconcileParentCompletion()._activeRootsFirst();
  }

  RichChecklistDocument replaceItemWith({
    required String id,
    required List<RichChecklistItem> replacements,
  }) {
    if (replacements.isEmpty) return this;
    final index = indexOfId(id);
    if (index < 0) return this;
    final end = subtreeEnd(index);
    final descendants = items.sublist(index + 1, end);
    final updated = [...items]
      ..removeRange(index, end)
      ..insertAll(index, [
        replacements.first,
        ...descendants,
        ...replacements.skip(1),
      ]);
    return RichChecklistDocument(updated)._activeRootsFirst();
  }

  RichChecklistDocument moveSubtreeBefore({
    required String id,
    required String targetId,
  }) {
    final from = indexOfId(id);
    final target = indexOfId(targetId);
    if (from < 0 || target < 0 || from == target) return this;
    if (items[from].indent != items[target].indent) return this;
    final fromEnd = subtreeEnd(from);
    if (target > from && target < fromEnd) return this;

    final moving = items.sublist(from, fromEnd);
    final updated = [...items]..removeRange(from, fromEnd);
    var insertionIndex = updated.indexWhere((item) => item.id == targetId);
    if (insertionIndex < 0) insertionIndex = updated.length;
    updated.insertAll(insertionIndex, moving);
    return RichChecklistDocument(updated)._activeRootsFirst();
  }

  RichChecklistDocument moveSubtreeAfter({
    required String id,
    required String targetId,
  }) {
    final from = indexOfId(id);
    final target = indexOfId(targetId);
    if (from < 0 || target < 0 || from == target) return this;
    if (items[from].indent != items[target].indent) return this;
    final fromEnd = subtreeEnd(from);
    if (target > from && target < fromEnd) return this;

    final moving = items.sublist(from, fromEnd);
    final updated = [...items]..removeRange(from, fromEnd);
    final adjustedTarget = updated.indexWhere((item) => item.id == targetId);
    if (adjustedTarget < 0) return this;
    final insertionIndex = _subtreeEndFor(updated, adjustedTarget);
    updated.insertAll(insertionIndex, moving);
    return RichChecklistDocument(updated)._activeRootsFirst();
  }

  int _previousSiblingIndex(int index) {
    final indent = items[index].indent;
    for (var candidate = index - 1; candidate >= 0; candidate--) {
      if (items[candidate].indent < indent) return -1;
      if (items[candidate].indent == indent) return candidate;
    }
    return -1;
  }

  int _parentIndex(int index) {
    final parentIndent = items[index].indent - 1;
    for (var candidate = index - 1; candidate >= 0; candidate--) {
      if (items[candidate].indent == parentIndent) return candidate;
    }
    return -1;
  }

  RichChecklistDocument _shiftSubtree(int index, int delta) {
    final end = subtreeEnd(index);
    final updated = [...items];
    for (var child = index; child < end; child++) {
      updated[child] = updated[child].copyWith(
        indent: updated[child].indent + delta,
      );
    }
    return RichChecklistDocument(
      updated,
    )._reconcileParentCompletion()._activeRootsFirst();
  }

  RichChecklistDocument _reconcileParentCompletion() {
    final updated = [...items];
    for (var parent = updated.length - 1; parent >= 0; parent--) {
      final childIndent = updated[parent].indent + 1;
      final end = _subtreeEndFor(updated, parent);
      var hasDirectChild = false;
      var allDirectChildrenChecked = true;
      for (var child = parent + 1; child < end; child++) {
        if (updated[child].indent != childIndent) continue;
        hasDirectChild = true;
        allDirectChildrenChecked &= updated[child].checked;
      }
      if (hasDirectChild) {
        updated[parent] = updated[parent].copyWith(
          checked: allDirectChildrenChecked,
        );
      }
    }
    return RichChecklistDocument(updated);
  }

  RichChecklistDocument _activeRootsFirst() {
    final active = <RichChecklistItem>[];
    final completed = <RichChecklistItem>[];
    var index = 0;
    while (index < items.length) {
      final end = subtreeEnd(index);
      final destination = items[index].checked ? completed : active;
      destination.addAll(items.sublist(index, end));
      index = end;
    }
    return RichChecklistDocument([...active, ...completed]);
  }
}

@immutable
class ChecklistBlockSlice {
  ChecklistBlockSlice({
    required this.startOffset,
    required this.endOffset,
    required this.baseIndent,
    required List<Map<String, dynamic>> sourceDelta,
    required this.sourceFingerprint,
    required this.document,
  }) : assert(startOffset >= 0),
       assert(endOffset > startOffset),
       assert(baseIndent >= 0),
       sourceDelta = List.unmodifiable(_deepCopyOperations(sourceDelta));

  final int startOffset;
  final int endOffset;
  final int baseIndent;
  final List<Map<String, dynamic>> sourceDelta;
  final String sourceFingerprint;
  final RichChecklistDocument document;

  int get length => endOffset - startOffset;
  String get identity => '$startOffset:$endOffset:$sourceFingerprint';

  ChecklistBlockSlice copyWith({
    int? startOffset,
    int? endOffset,
    int? baseIndent,
    List<Map<String, dynamic>>? sourceDelta,
    String? sourceFingerprint,
    RichChecklistDocument? document,
  }) => ChecklistBlockSlice(
    startOffset: startOffset ?? this.startOffset,
    endOffset: endOffset ?? this.endOffset,
    baseIndent: baseIndent ?? this.baseIndent,
    sourceDelta: sourceDelta ?? this.sourceDelta,
    sourceFingerprint: sourceFingerprint ?? this.sourceFingerprint,
    document: document ?? this.document,
  );
}

@immutable
class ChecklistBlockEditSession {
  ChecklistBlockEditSession({
    required this.title,
    required List<Map<String, dynamic>> bodyDelta,
    required this.block,
    required this.selectionStart,
    required this.selectionEnd,
    this.blockOrdinal = 0,
  }) : bodyDelta = List.unmodifiable(_deepCopyOperations(bodyDelta));

  final String title;
  final List<Map<String, dynamic>> bodyDelta;
  final ChecklistBlockSlice block;
  final int selectionStart;
  final int selectionEnd;
  final int blockOrdinal;
}

@immutable
class RichChecklistSection {
  RichChecklistSection({
    required this.id,
    required this.ordinal,
    required this.startOffset,
    required this.endOffset,
    required List<Map<String, dynamic>> sourceDelta,
    required this.sourceFingerprint,
    required this.checkedCount,
    required this.totalCount,
    this.contextLabel,
    this.block,
    this.document,
    this.failureReason,
    this.failureMessage,
  }) : assert(startOffset >= 0),
       assert(endOffset > startOffset),
       assert(totalCount > 0),
       assert(checkedCount >= 0 && checkedCount <= totalCount),
       assert((block != null && document != null) || failureReason != null),
       sourceDelta = List.unmodifiable(_deepCopyOperations(sourceDelta));

  final String id;
  final int ordinal;
  final int startOffset;
  final int endOffset;
  final List<Map<String, dynamic>> sourceDelta;
  final String sourceFingerprint;
  final String? contextLabel;
  final ChecklistBlockSlice? block;
  final RichChecklistDocument? document;
  final ChecklistDeltaFailureReason? failureReason;
  final String? failureMessage;
  final int checkedCount;
  final int totalCount;

  bool get isEligible => block != null && document != null;
  int get length => endOffset - startOffset;

  RichChecklistSection withDocument(
    RichChecklistDocument value, {
    ChecklistBlockSlice? updatedBlock,
  }) => RichChecklistSection(
    id: id,
    ordinal: ordinal,
    startOffset: updatedBlock?.startOffset ?? startOffset,
    endOffset: updatedBlock?.endOffset ?? endOffset,
    sourceDelta: updatedBlock?.sourceDelta ?? sourceDelta,
    sourceFingerprint: updatedBlock?.sourceFingerprint ?? sourceFingerprint,
    contextLabel: contextLabel,
    block: updatedBlock ?? block,
    document: value,
    checkedCount: value.items.where((item) => item.checked).length,
    totalCount: value.items.length,
  );

  RichChecklistSection rebase({
    required int startOffset,
    required int endOffset,
    required List<Map<String, dynamic>> sourceDelta,
    required String sourceFingerprint,
    required String? contextLabel,
    ChecklistBlockSlice? block,
    RichChecklistDocument? document,
    ChecklistDeltaFailureReason? failureReason,
    String? failureMessage,
    required int checkedCount,
    required int totalCount,
  }) => RichChecklistSection(
    id: id,
    ordinal: ordinal,
    startOffset: startOffset,
    endOffset: endOffset,
    sourceDelta: sourceDelta,
    sourceFingerprint: sourceFingerprint,
    contextLabel: contextLabel,
    block: block,
    document: document,
    failureReason: failureReason,
    failureMessage: failureMessage,
    checkedCount: checkedCount,
    totalCount: totalCount,
  );
}

@immutable
class RichChecklistCollection {
  RichChecklistCollection(Iterable<RichChecklistSection> sections)
    : sections = List.unmodifiable(sections) {
    if (this.sections.isEmpty) {
      throw ArgumentError.value(
        sections,
        'sections',
        'Checklist collection cannot be empty',
      );
    }
    final ids = this.sections.map((section) => section.id).toSet();
    if (ids.length != this.sections.length) {
      throw ArgumentError.value(sections, 'sections', 'Duplicate section IDs');
    }
  }

  final List<RichChecklistSection> sections;

  int get totalCount =>
      sections.fold(0, (total, section) => total + section.totalCount);
  int get checkedCount =>
      sections.fold(0, (total, section) => total + section.checkedCount);

  RichChecklistSection? sectionById(String id) {
    for (final section in sections) {
      if (section.id == id) return section;
    }
    return null;
  }

  RichChecklistDocument? documentFor(String sectionId) =>
      sectionById(sectionId)?.document;

  RichChecklistCollection replaceDocument(
    String sectionId,
    RichChecklistDocument document,
  ) {
    final index = sections.indexWhere((section) => section.id == sectionId);
    if (index < 0 || !sections[index].isEligible) return this;
    final updated = [...sections]
      ..[index] = sections[index].withDocument(document);
    return RichChecklistCollection(updated);
  }

  RichChecklistCollection rebaseMetadataFrom(RichChecklistCollection source) {
    if (sections.length != source.sections.length) return source;
    final rebased = <RichChecklistSection>[];
    for (var index = 0; index < sections.length; index++) {
      final local = sections[index];
      final metadata = source.sections[index];
      if (local.isEligible != metadata.isEligible) return source;
      final document = local.document;
      final block = metadata.block == null || document == null
          ? null
          : metadata.block!.copyWith(document: document);
      rebased.add(
        RichChecklistSection(
          id: local.id,
          ordinal: metadata.ordinal,
          startOffset: metadata.startOffset,
          endOffset: metadata.endOffset,
          sourceDelta: metadata.sourceDelta,
          sourceFingerprint: metadata.sourceFingerprint,
          contextLabel: metadata.contextLabel,
          block: block,
          document: document,
          failureReason: metadata.failureReason,
          failureMessage: metadata.failureMessage,
          checkedCount: document == null
              ? metadata.checkedCount
              : document.items.where((item) => item.checked).length,
          totalCount: document?.items.length ?? metadata.totalCount,
        ),
      );
    }
    return RichChecklistCollection(rebased);
  }

  List<Map<String, dynamic>> toSnapshotJson() => sections
      .map(
        (section) => {
          'id': section.id,
          if (section.document != null)
            'document': section.document!.toSnapshotJson(),
        },
      )
      .toList(growable: false);
}

@immutable
class ChecklistCollectionEditSession {
  ChecklistCollectionEditSession({
    required this.title,
    required List<Map<String, dynamic>> bodyDelta,
    required this.collection,
    required this.selectionStart,
    required this.selectionEnd,
  }) : bodyDelta = List.unmodifiable(_deepCopyOperations(bodyDelta));

  final String title;
  final List<Map<String, dynamic>> bodyDelta;
  final RichChecklistCollection collection;
  final int selectionStart;
  final int selectionEnd;
}

@immutable
class ChecklistCollectionReplacement {
  ChecklistCollectionReplacement({
    required this.sectionId,
    required this.startOffset,
    required this.sourceLength,
    required this.sourceFingerprint,
    required List<Map<String, dynamic>> replacementDelta,
  }) : replacementDelta = List.unmodifiable(
         _deepCopyOperations(replacementDelta),
       );

  final String sectionId;
  final int startOffset;
  final int sourceLength;
  final String sourceFingerprint;
  final List<Map<String, dynamic>> replacementDelta;
}

@immutable
class ChecklistCollectionSpliceResult {
  ChecklistCollectionSpliceResult({
    required List<Map<String, dynamic>> bodyDelta,
    required this.collection,
    required List<ChecklistCollectionReplacement> replacements,
  }) : bodyDelta = List.unmodifiable(_deepCopyOperations(bodyDelta)),
       replacements = List.unmodifiable(replacements);

  final List<Map<String, dynamic>> bodyDelta;
  final RichChecklistCollection collection;
  final List<ChecklistCollectionReplacement> replacements;
}

@immutable
class RichChecklistCollectionEditorResult {
  RichChecklistCollectionEditorResult({
    required this.title,
    required this.content,
    required this.plainText,
    required List<Map<String, dynamic>> bodyDelta,
    required List<ChecklistCollectionReplacement> replacements,
    required this.selectionStart,
    required this.selectionEnd,
    this.requiresFullRefresh = false,
  }) : bodyDelta = List.unmodifiable(_deepCopyOperations(bodyDelta)),
       replacements = List.unmodifiable(replacements);

  final String title;
  final String content;
  final String plainText;
  final List<Map<String, dynamic>> bodyDelta;
  final List<ChecklistCollectionReplacement> replacements;
  final int selectionStart;
  final int selectionEnd;
  final bool requiresFullRefresh;
}

@immutable
class RichChecklistEditorResult {
  const RichChecklistEditorResult({
    required this.title,
    required this.content,
    required this.plainText,
    required this.document,
    required this.bodyDelta,
    required this.replacementDelta,
    required this.replacementStart,
    required this.replacementLength,
    required this.sourceFingerprint,
    required this.selectionStart,
    required this.selectionEnd,
    this.requiresFullRefresh = false,
  });

  final String title;
  final String content;
  final String plainText;
  final RichChecklistDocument document;
  final List<Map<String, dynamic>> bodyDelta;
  final List<Map<String, dynamic>> replacementDelta;
  final int replacementStart;
  final int replacementLength;
  final String sourceFingerprint;
  final int selectionStart;
  final int selectionEnd;
  final bool requiresFullRefresh;
}

@immutable
class ChecklistCollectionHistorySelection {
  const ChecklistCollectionHistorySelection({
    this.sectionId,
    this.itemId,
    this.baseOffset = 0,
    this.extentOffset = 0,
  });

  final String? sectionId;
  final String? itemId;
  final int baseOffset;
  final int extentOffset;
}

@immutable
class ChecklistCollectionHistoryEntry {
  const ChecklistCollectionHistoryEntry({
    required this.collection,
    this.selection,
  });

  final RichChecklistCollection collection;
  final ChecklistCollectionHistorySelection? selection;
}

@immutable
class ChecklistHistorySelection {
  const ChecklistHistorySelection({
    this.itemId,
    this.baseOffset = 0,
    this.extentOffset = 0,
  });

  final String? itemId;
  final int baseOffset;
  final int extentOffset;
}

@immutable
class ChecklistHistoryEntry {
  const ChecklistHistoryEntry({required this.document, this.selection});

  final RichChecklistDocument document;
  final ChecklistHistorySelection? selection;
}

class ChecklistHistoryController extends ChangeNotifier {
  ChecklistHistoryController(RichChecklistDocument initial)
    : _current = ChecklistHistoryEntry(document: initial);

  static const coalesceWindow = Duration(milliseconds: 600);

  ChecklistHistoryEntry _current;
  final List<ChecklistHistoryEntry> _undo = [];
  final List<ChecklistHistoryEntry> _redo = [];
  String? _lastCoalesceKey;
  DateTime? _lastCommitAt;

  ChecklistHistoryEntry get current => _current;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void commit(
    RichChecklistDocument document, {
    ChecklistHistorySelection? selection,
    String? coalesceKey,
    DateTime? now,
  }) {
    if (_sameDocument(_current.document, document)) {
      if (!_sameSelection(_current.selection, selection)) {
        _current = ChecklistHistoryEntry(
          document: document,
          selection: selection,
        );
      }
      return;
    }
    final commitAt = now ?? DateTime.now();
    final shouldCoalesce =
        coalesceKey != null &&
        coalesceKey == _lastCoalesceKey &&
        _lastCommitAt != null &&
        commitAt.difference(_lastCommitAt!) <= coalesceWindow;
    if (!shouldCoalesce) _undo.add(_current);
    _current = ChecklistHistoryEntry(document: document, selection: selection);
    _redo.clear();
    _lastCoalesceKey = coalesceKey;
    _lastCommitAt = commitAt;
    notifyListeners();
  }

  ChecklistHistoryEntry? undo() {
    if (!canUndo) return null;
    _redo.add(_current);
    _current = _undo.removeLast();
    _resetCoalescing();
    notifyListeners();
    return _current;
  }

  ChecklistHistoryEntry? redo() {
    if (!canRedo) return null;
    _undo.add(_current);
    _current = _redo.removeLast();
    _resetCoalescing();
    notifyListeners();
    return _current;
  }

  void replaceWithoutHistory(
    RichChecklistDocument document, {
    ChecklistHistorySelection? selection,
  }) {
    _current = ChecklistHistoryEntry(document: document, selection: selection);
    _undo.clear();
    _redo.clear();
    _resetCoalescing();
    notifyListeners();
  }

  void _resetCoalescing() {
    _lastCoalesceKey = null;
    _lastCommitAt = null;
  }
}

class ChecklistCollectionHistoryController extends ChangeNotifier {
  ChecklistCollectionHistoryController(RichChecklistCollection initial)
    : _current = ChecklistCollectionHistoryEntry(collection: initial);

  static const coalesceWindow = Duration(milliseconds: 600);

  ChecklistCollectionHistoryEntry _current;
  final List<ChecklistCollectionHistoryEntry> _undo = [];
  final List<ChecklistCollectionHistoryEntry> _redo = [];
  String? _lastCoalesceKey;
  DateTime? _lastCommitAt;

  ChecklistCollectionHistoryEntry get current => _current;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void commit(
    RichChecklistCollection collection, {
    ChecklistCollectionHistorySelection? selection,
    String? coalesceKey,
    DateTime? now,
  }) {
    if (_sameCollection(_current.collection, collection)) {
      if (!_sameCollectionSelection(_current.selection, selection)) {
        _current = ChecklistCollectionHistoryEntry(
          collection: collection,
          selection: selection,
        );
      }
      return;
    }
    final commitAt = now ?? DateTime.now();
    final shouldCoalesce =
        coalesceKey != null &&
        coalesceKey == _lastCoalesceKey &&
        _lastCommitAt != null &&
        commitAt.difference(_lastCommitAt!) <= coalesceWindow;
    if (!shouldCoalesce) _undo.add(_current);
    _current = ChecklistCollectionHistoryEntry(
      collection: collection,
      selection: selection,
    );
    _redo.clear();
    _lastCoalesceKey = coalesceKey;
    _lastCommitAt = commitAt;
    notifyListeners();
  }

  ChecklistCollectionHistoryEntry? undo() {
    if (!canUndo) return null;
    _redo.add(_current);
    _current = _undo.removeLast();
    _resetCoalescing();
    notifyListeners();
    return _current;
  }

  ChecklistCollectionHistoryEntry? redo() {
    if (!canRedo) return null;
    _undo.add(_current);
    _current = _redo.removeLast();
    _resetCoalescing();
    notifyListeners();
    return _current;
  }

  void replaceWithoutHistory(
    RichChecklistCollection collection, {
    ChecklistCollectionHistorySelection? selection,
  }) {
    _current = ChecklistCollectionHistoryEntry(
      collection: collection,
      selection: selection,
    );
    _undo.clear();
    _redo.clear();
    _resetCoalescing();
    notifyListeners();
  }

  void rebaseSources(RichChecklistCollection source) {
    ChecklistCollectionHistoryEntry rebase(
      ChecklistCollectionHistoryEntry entry,
    ) => ChecklistCollectionHistoryEntry(
      collection: entry.collection.rebaseMetadataFrom(source),
      selection: entry.selection,
    );

    _current = rebase(_current);
    for (var index = 0; index < _undo.length; index++) {
      _undo[index] = rebase(_undo[index]);
    }
    for (var index = 0; index < _redo.length; index++) {
      _redo[index] = rebase(_redo[index]);
    }
  }

  void _resetCoalescing() {
    _lastCoalesceKey = null;
    _lastCommitAt = null;
  }
}

int _subtreeEndFor(List<RichChecklistItem> items, int index) {
  final indent = items[index].indent;
  var end = index + 1;
  while (end < items.length && items[end].indent > indent) {
    end++;
  }
  return end;
}

List<Map<String, dynamic>> _deepCopyOperations(
  List<Map<String, dynamic>> operations,
) => operations
    .map((operation) => _deepCopyMap(operation))
    .toList(growable: false);

Map<String, dynamic> _deepCopyMap(Map<dynamic, dynamic> source) =>
    Map<String, dynamic>.from(
      jsonDecode(jsonEncode(source)) as Map<String, dynamic>,
    );

bool _sameDocument(RichChecklistDocument left, RichChecklistDocument right) =>
    jsonEncode(left.toSnapshotJson()) == jsonEncode(right.toSnapshotJson());

bool _sameSelection(
  ChecklistHistorySelection? left,
  ChecklistHistorySelection? right,
) =>
    left?.itemId == right?.itemId &&
    left?.baseOffset == right?.baseOffset &&
    left?.extentOffset == right?.extentOffset;

bool _sameCollection(
  RichChecklistCollection left,
  RichChecklistCollection right,
) => jsonEncode(left.toSnapshotJson()) == jsonEncode(right.toSnapshotJson());

bool _sameCollectionSelection(
  ChecklistCollectionHistorySelection? left,
  ChecklistCollectionHistorySelection? right,
) =>
    left?.sectionId == right?.sectionId &&
    left?.itemId == right?.itemId &&
    left?.baseOffset == right?.baseOffset &&
    left?.extentOffset == right?.extentOffset;
