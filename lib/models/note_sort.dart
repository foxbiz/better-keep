import 'dart:convert';

import 'package:flutter/foundation.dart';

enum NoteSortMode { custom, createdNewest, updatedNewest }

enum NoteOrderContextKind {
  main,
  pinnedFolder,
  labelFolder,
  colorFolder,
  system,
}

@immutable
class NoteOrderContext {
  const NoteOrderContext._({
    required this.kind,
    required this.key,
    this.scopeId,
  });

  const NoteOrderContext.mainGrid()
    : this._(kind: NoteOrderContextKind.main, key: 'main:grid');

  const NoteOrderContext.mainList()
    : this._(kind: NoteOrderContextKind.main, key: 'main:list');

  const NoteOrderContext.pinned()
    : this._(kind: NoteOrderContextKind.pinnedFolder, key: 'folder:pinned');

  factory NoteOrderContext.label(String stableLabelId) {
    final encoded = Uri.encodeComponent(stableLabelId);
    return NoteOrderContext._(
      kind: NoteOrderContextKind.labelFolder,
      key: 'folder:label:$encoded',
      scopeId: stableLabelId,
    );
  }

  factory NoteOrderContext.color(int argb) => NoteOrderContext._(
    kind: NoteOrderContextKind.colorFolder,
    key: 'folder:color:${argb.toUnsigned(32)}',
    scopeId: argb.toUnsigned(32).toString(),
  );

  factory NoteOrderContext.system(String collection) {
    final encoded = Uri.encodeComponent(collection);
    return NoteOrderContext._(
      kind: NoteOrderContextKind.system,
      key: 'system:$encoded',
      scopeId: collection,
    );
  }

  final NoteOrderContextKind kind;
  final String key;
  final String? scopeId;

  bool get reorderable => kind != NoteOrderContextKind.system;

  bool get isMainGrid => key == 'main:grid';
  bool get isMainList => key == 'main:list';

  static NoteOrderContext? tryParse(String value) {
    if (value == 'main:grid') return const NoteOrderContext.mainGrid();
    if (value == 'main:list') return const NoteOrderContext.mainList();
    if (value == 'folder:pinned') return const NoteOrderContext.pinned();
    if (value.startsWith('folder:label:')) {
      final encoded = value.substring('folder:label:'.length);
      if (encoded.isEmpty) return null;
      return NoteOrderContext.label(Uri.decodeComponent(encoded));
    }
    if (value.startsWith('folder:color:')) {
      final color = int.tryParse(value.substring('folder:color:'.length));
      return color == null ? null : NoteOrderContext.color(color);
    }
    if (value.startsWith('system:')) {
      final encoded = value.substring('system:'.length);
      if (encoded.isEmpty) return null;
      return NoteOrderContext.system(Uri.decodeComponent(encoded));
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is NoteOrderContext && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

@immutable
class NoteOrderSnapshot {
  const NoteOrderSnapshot({
    required this.context,
    required this.mode,
    required this.orderedNoteIds,
    required this.revision,
    required this.updatedAt,
    this.baseRevision,
    this.dirty = false,
    this.hydrated = false,
  });

  final NoteOrderContext context;
  final NoteSortMode mode;
  final List<String> orderedNoteIds;
  final String revision;
  final String? baseRevision;
  final DateTime updatedAt;
  final bool dirty;
  final bool hydrated;

  NoteOrderSnapshot copyWith({
    NoteOrderContext? context,
    NoteSortMode? mode,
    List<String>? orderedNoteIds,
    String? revision,
    String? baseRevision,
    bool clearBaseRevision = false,
    DateTime? updatedAt,
    bool? dirty,
    bool? hydrated,
  }) {
    return NoteOrderSnapshot(
      context: context ?? this.context,
      mode: mode ?? this.mode,
      orderedNoteIds: List<String>.unmodifiable(
        orderedNoteIds ?? this.orderedNoteIds,
      ),
      revision: revision ?? this.revision,
      baseRevision: clearBaseRevision
          ? null
          : (baseRevision ?? this.baseRevision),
      updatedAt: updatedAt ?? this.updatedAt,
      dirty: dirty ?? this.dirty,
      hydrated: hydrated ?? this.hydrated,
    );
  }

  Map<String, Object?> toDatabaseJson() => {
    'context_key': context.key,
    'sort_mode': mode.name,
    'revision': revision,
    'base_revision': baseRevision,
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'dirty': dirty ? 1 : 0,
    'hydrated': hydrated ? 1 : 0,
  };

  static NoteOrderSnapshot? tryFromDatabaseJson(
    Map<String, Object?> row, {
    Iterable<String> orderedNoteIds = const [],
  }) {
    try {
      final context = NoteOrderContext.tryParse(
        row['context_key'] as String? ?? '',
      );
      final modeName = row['sort_mode'] as String?;
      final revision = row['revision'] as String?;
      final updatedAt = DateTime.tryParse(row['updated_at'] as String? ?? '');
      if (context == null ||
          modeName == null ||
          revision == null ||
          revision.isEmpty ||
          updatedAt == null) {
        return null;
      }
      final mode = NoteSortMode.values.firstWhere(
        (candidate) => candidate.name == modeName,
      );
      final ids = <String>[];
      final seen = <String>{};
      for (final value in orderedNoteIds) {
        if (value.isEmpty || !seen.add(value)) return null;
        ids.add(value);
      }
      return NoteOrderSnapshot(
        context: context,
        mode: mode,
        orderedNoteIds: List<String>.unmodifiable(ids),
        revision: revision,
        baseRevision: row['base_revision'] as String?,
        updatedAt: updatedAt,
        dirty: row['dirty'] == 1 || row['dirty'] == true,
        hydrated: row['hydrated'] == 1 || row['hydrated'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

enum NoteOrderOperationType { setMode, insertNote, deleteNote, moveNote }

@immutable
class NoteOrderOperation {
  const NoteOrderOperation({
    required this.id,
    required this.contextKey,
    required this.type,
    required this.createdAt,
    this.noteId,
    this.beforeId,
    this.afterId,
    this.mode,
  });

  final String id;
  final String contextKey;
  final NoteOrderOperationType type;
  final DateTime createdAt;
  final String? noteId;
  final String? beforeId;
  final String? afterId;
  final NoteSortMode? mode;

  Map<String, Object?> toDatabaseJson() => {
    'id': id,
    'context_key': contextKey,
    'operation_type': type.name,
    'payload': jsonEncode({
      if (noteId != null) 'note_id': noteId,
      if (beforeId != null) 'before_id': beforeId,
      if (afterId != null) 'after_id': afterId,
      if (mode != null) 'mode': mode!.name,
    }),
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  static NoteOrderOperation? tryFromDatabaseJson(Map<String, Object?> row) {
    try {
      final payload = Map<String, dynamic>.from(
        jsonDecode(row['payload'] as String) as Map,
      );
      final type = NoteOrderOperationType.values.byName(
        row['operation_type'] as String,
      );
      final modeName = payload['mode'] as String?;
      return NoteOrderOperation(
        id: row['id'] as String,
        contextKey: row['context_key'] as String,
        type: type,
        createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
        noteId: payload['note_id'] as String?,
        beforeId: payload['before_id'] as String?,
        afterId: payload['after_id'] as String?,
        mode: modeName == null ? null : NoteSortMode.values.byName(modeName),
      );
    } catch (_) {
      return null;
    }
  }
}

class PinnedSectionReorderException implements Exception {
  const PinnedSectionReorderException();

  @override
  String toString() => 'Notes cannot be moved across pinned sections';
}
