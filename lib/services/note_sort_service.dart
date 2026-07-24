import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:better_keep/config.dart' show demoAccountEmail;
import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/initial_hydration_gate.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/note_sort_cloud_repository.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class NoteSortService {
  NoteSortService._();

  factory NoteSortService() => _instance;

  static final NoteSortService _instance = NoteSortService._();

  static const int cloudSchemaVersion = 2;
  static const int legacyCloudSchemaVersion = 1;
  static const int cloudChunkSize = 2000;
  static const int maxCloudChunks = 500;

  static const String legacyTableName = 'note_sort_state';
  static const String tableName = 'note_sort_context';
  static const String positionTableName = 'note_sort_position';
  static const String operationTableName = 'note_sort_operation';
  static const String cleanupTableName = 'note_sort_cloud_cleanup';

  static const _contextCollection = 'note_order_contexts';
  static const _legacyManifestCollection = 'preferences';
  static const _legacyManifestDocument = 'note_sort';
  static const _legacySnapshotCollection = 'note_order_snapshots';
  static const _cloudDebounce = Duration(milliseconds: 500);

  @visibleForTesting
  static bool? canPushCloudOverride;

  @visibleForTesting
  static bool? canReceiveCloudOverride;

  @visibleForTesting
  static NoteSortCloudRepository? cloudRepositoryOverride;

  final ValueNotifier<Map<String, NoteOrderSnapshot>> snapshots = ValueNotifier(
    const {},
  );
  final AsyncKeyedSerializer<String> _mutations = AsyncKeyedSerializer();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _remoteListener;
  Timer? _cloudWriteTimer;
  Future<void>? _activeUpload;
  FirebaseFirestore? _firestoreInstance;
  NoteSortCloudRepository? _cloudRepositoryInstance;
  Timer? _cleanupTimer;
  bool _cleanupRunning = false;
  bool _initialized = false;
  bool _cloudInitialized = false;
  bool _remoteInitialResolved = false;
  final InitialHydrationGate _remoteHydration = InitialHydrationGate();
  final HydrationRetryController _remoteListenerRetry =
      HydrationRetryController();
  bool _dataHydrated = false;
  bool _bootstrapReady = false;
  bool _legacyMigrationAttempted = false;
  bool _uploading = false;
  bool _uploadAgain = false;
  final Set<String> _activeDragContexts = {};
  final Map<String, NoteOrderSnapshot> _deferredRemote = {};
  final Map<String, int> _remoteChunkCounts = {};
  final Set<String> _remoteContextKeys = {};

  FirebaseFirestore get _firestore {
    _firestoreInstance ??= FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: DefaultFirebaseOptions.databaseId,
    );
    return _firestoreInstance!;
  }

  CollectionReference<Map<String, dynamic>> get _contextCollectionRef =>
      _firestore
          .collection('users')
          .doc(AuthService.currentUser!.uid)
          .collection(_contextCollection);

  NoteSortCloudRepository get _cloudRepository =>
      cloudRepositoryOverride ??
      (_cloudRepositoryInstance ??= FirestoreNoteSortCloudRepository(
        firestore: _firestore,
        userId: AuthService.currentUser!.uid,
        schemaVersion: cloudSchemaVersion,
      ));

  DocumentReference<Map<String, dynamic>> get _legacyManifestRef => _firestore
      .collection('users')
      .doc(AuthService.currentUser!.uid)
      .collection(_legacyManifestCollection)
      .doc(_legacyManifestDocument);

  DocumentReference<Map<String, dynamic>> _legacyChunkRef(
    String revision,
    int index,
  ) => _firestore
      .collection('users')
      .doc(AuthService.currentUser!.uid)
      .collection(_legacySnapshotCollection)
      .doc(revision)
      .collection('chunks')
      .doc(index.toString().padLeft(6, '0'));

  bool get _canReceiveCloud {
    if (canReceiveCloudOverride != null) return canReceiveCloudOverride!;
    try {
      final user = AuthService.currentUser;
      return user != null &&
          !AuthService.sessionInvalid.value &&
          user.email?.toLowerCase() != demoAccountEmail.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  bool get _canPushCloud =>
      canPushCloudOverride ?? (_canReceiveCloud && PlanService.instance.isPaid);

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $legacyTableName (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        sort_mode TEXT NOT NULL,
        ordered_note_ids TEXT NOT NULL DEFAULT '[]',
        revision TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName (
        context_key TEXT PRIMARY KEY,
        sort_mode TEXT NOT NULL,
        revision TEXT NOT NULL,
        base_revision TEXT,
        updated_at TEXT NOT NULL,
        dirty INTEGER NOT NULL DEFAULT 0,
        hydrated INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $positionTableName (
        context_key TEXT NOT NULL,
        note_sync_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        PRIMARY KEY (context_key, note_sync_id),
        UNIQUE (context_key, position),
        FOREIGN KEY (context_key) REFERENCES $tableName(context_key)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $operationTableName (
        id TEXT PRIMARY KEY,
        context_key TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (context_key) REFERENCES $tableName(context_key)
          ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_note_sort_operation_context '
      'ON $operationTableName(context_key, created_at)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $cleanupTableName (
        revision TEXT PRIMARY KEY,
        context_key TEXT NOT NULL,
        chunk_count INTEGER NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        next_retry_at TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_note_sort_cleanup_retry '
      'ON $cleanupTableName(next_retry_at)',
    );
  }

  static Future<void> upgradeTable(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 9 && newVersion >= 8) {
      await createTable(db);
    }
    if (oldVersion < 8 && newVersion >= 8) {
      await _migrateLegacyLocalState(db);
    }
  }

  static Future<void> _migrateLegacyLocalState(Database db) async {
    final existing = await db.query(tableName, limit: 1);
    if (existing.isNotEmpty) return;

    final legacyRows = await db.query(legacyTableName, limit: 1);
    final legacy = legacyRows.isEmpty ? null : legacyRows.first;
    final modeName = legacy?['sort_mode'] as String?;
    final mode = NoteSortMode.values
        .where((candidate) => candidate.name == modeName)
        .firstOrNull;
    final revision = legacy?['revision'] as String? ?? const Uuid().v4();
    final updatedAt =
        legacy?['updated_at'] as String? ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String();
    final dirty = legacy?['dirty'] == 1 || legacy?['dirty'] == true;

    final legacyIds = <int>[];
    try {
      final decoded = jsonDecode(
        legacy?['ordered_note_ids'] as String? ?? '[]',
      );
      if (decoded is List) {
        legacyIds.addAll(decoded.whereType<int>());
      }
    } catch (_) {
      // A corrupt legacy row is safely replaced by deterministic date order.
    }

    final noteRows = await db.rawQuery('''
      SELECT id, sync_id
      FROM note
      ORDER BY pinned DESC, updated_at DESC, created_at DESC, id DESC
    ''');
    final byLocalId = <int, String>{
      for (final row in noteRows)
        if (row['id'] is int && row['sync_id'] is String)
          row['id'] as int: row['sync_id'] as String,
    };
    final ordered = <String>[];
    final seen = <String>{};
    for (final id in legacyIds) {
      final stableId = byLocalId[id];
      if (stableId != null && seen.add(stableId)) ordered.add(stableId);
    }
    for (final row in noteRows) {
      final stableId = row['sync_id'] as String?;
      if (stableId != null && seen.add(stableId)) ordered.add(stableId);
    }

    await db.transaction((txn) async {
      for (final context in const [
        NoteOrderContext.mainGrid(),
        NoteOrderContext.mainList(),
      ]) {
        await txn.insert(tableName, {
          'context_key': context.key,
          'sort_mode': (mode ?? NoteSortMode.updatedNewest).name,
          'revision': revision,
          'base_revision': null,
          'updated_at': updatedAt,
          'dirty': dirty ? 1 : 0,
          'hydrated': 0,
        });
        for (final entry in ordered.indexed) {
          await txn.insert(positionTableName, {
            'context_key': context.key,
            'note_sync_id': entry.$2,
            'position': entry.$1,
          });
        }
      }
    });
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await createTable(AppState.db);
    await _migrateLegacyLocalState(AppState.db);
    await _loadSnapshots();
    Note.on('changed', _handleNoteEvent);
  }

  Future<void> _loadSnapshots() async {
    final rows = await AppState.db.query(tableName);
    final loaded = <String, NoteOrderSnapshot>{};
    for (final row in rows) {
      final contextKey = row['context_key'] as String?;
      if (contextKey == null) continue;
      final positions = await AppState.db.query(
        positionTableName,
        columns: ['note_sync_id'],
        where: 'context_key = ?',
        whereArgs: [contextKey],
        orderBy: 'position ASC',
      );
      final snapshot = NoteOrderSnapshot.tryFromDatabaseJson(
        row,
        orderedNoteIds: positions
            .map((position) => position['note_sync_id'])
            .whereType<String>(),
      );
      if (snapshot != null) loaded[contextKey] = snapshot;
    }
    snapshots.value = Map.unmodifiable(loaded);
  }

  NoteOrderSnapshot snapshotFor(NoteOrderContext context) {
    return snapshots.value[context.key] ?? _defaultSnapshot(context);
  }

  NoteOrderSnapshot _defaultSnapshot(NoteOrderContext context) =>
      NoteOrderSnapshot(
        context: context,
        mode: NoteSortMode.updatedNewest,
        orderedNoteIds: const [],
        revision: const Uuid().v4(),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  Future<NoteOrderSnapshot> ensureContext(
    NoteOrderContext context, {
    Iterable<Note>? visibleNotes,
  }) => _mutations.run(
    context.key,
    () => _ensureContextUnlocked(context, visibleNotes: visibleNotes),
  );

  Future<NoteOrderSnapshot> _ensureContextUnlocked(
    NoteOrderContext context, {
    Iterable<Note>? visibleNotes,
  }) async {
    await init();
    final existing = snapshots.value[context.key];
    if (existing != null) return existing;

    final notes = visibleNotes?.toList() ?? await _loadNotesForContext(context);
    final legacyMode = await _legacyMode();
    final legacyPositions = await _legacyStablePositions();
    notes.sort(_compareSeedOrder);
    final ids = notes.map(_stableId).whereType<String>().toList(growable: true);
    if (legacyPositions.isNotEmpty) {
      ids.sort((a, b) {
        final positionA = legacyPositions[a];
        final positionB = legacyPositions[b];
        if (positionA == null && positionB == null) return 0;
        if (positionA == null) return 1;
        if (positionB == null) return -1;
        return positionA.compareTo(positionB);
      });
    }
    final seeded = NoteOrderSnapshot(
      context: context,
      mode: context.reorderable ? legacyMode : _dateMode(legacyMode),
      orderedNoteIds: List.unmodifiable(ids),
      revision: const Uuid().v4(),
      updatedAt: DateTime.now().toUtc(),
    );
    await _persistSnapshot(seeded);
    _publishSnapshot(seeded);
    return seeded;
  }

  Future<T> _mutateLatestSnapshot<T>(
    NoteOrderContext context,
    Future<T> Function(NoteOrderSnapshot current) mutation, {
    Iterable<Note>? visibleNotes,
  }) => _mutations.run(context.key, () async {
    final current = await _ensureContextUnlocked(
      context,
      visibleNotes: visibleNotes,
    );
    return mutation(current);
  });

  Future<NoteSortMode> _legacyMode() async {
    final rows = await AppState.db.query(legacyTableName, limit: 1);
    if (rows.isEmpty) return NoteSortMode.updatedNewest;
    final name = rows.first['sort_mode'] as String?;
    return NoteSortMode.values
            .where((candidate) => candidate.name == name)
            .firstOrNull ??
        NoteSortMode.updatedNewest;
  }

  Future<Map<String, int>> _legacyStablePositions() async {
    final rows = await AppState.db.query(legacyTableName, limit: 1);
    if (rows.isEmpty) return const {};
    try {
      final ids = (jsonDecode(rows.first['ordered_note_ids'] as String) as List)
          .whereType<int>()
          .toList();
      if (ids.isEmpty) return const {};
      final placeholders = List.filled(ids.length, '?').join(',');
      final noteRows = await AppState.db.rawQuery(
        'SELECT id, sync_id FROM note WHERE id IN ($placeholders)',
        ids,
      );
      final stableByLocal = <int, String>{
        for (final row in noteRows)
          if (row['id'] is int && row['sync_id'] is String)
            row['id'] as int: row['sync_id'] as String,
      };
      return {
        for (final entry in ids.indexed)
          if (stableByLocal[entry.$2] != null)
            stableByLocal[entry.$2]!: entry.$1,
      };
    } catch (_) {
      return const {};
    }
  }

  Future<List<Note>> _loadNotesForContext(NoteOrderContext context) async {
    switch (context.kind) {
      case NoteOrderContextKind.main:
        return Note.get(NoteType.all);
      case NoteOrderContextKind.pinnedFolder:
        return Note.get(NoteType.pinned);
      case NoteOrderContextKind.labelFolder:
        if (context.scopeId == '__unlabeled__') {
          return Note.filterByLabels(null);
        }
        final label = await Label.findBySyncId(context.scopeId!);
        if (label == null) return [];
        return Note.filterByLabels(label.name.isEmpty ? null : [label.name]);
      case NoteOrderContextKind.colorFolder:
        return Note.filterByColor(Color(int.parse(context.scopeId!)));
      case NoteOrderContextKind.system:
        final type = NoteType.values
            .where((candidate) => candidate.name == context.scopeId)
            .firstOrNull;
        return type == null ? [] : Note.get(type);
    }
  }

  Future<void> setMode(NoteOrderContext context, NoteSortMode mode) =>
      _mutateLatestSnapshot(context, (current) async {
        if (!context.reorderable && mode == NoteSortMode.custom) return;
        if (current.mode == mode) return;
        var ids = current.orderedNoteIds;
        if (mode == NoteSortMode.custom && ids.isEmpty) {
          final notes = await _loadNotesForContext(context);
          notes.sort(_compareSeedOrder);
          ids = notes.map(_stableId).whereType<String>().toList();
        }
        await _commit(
          current.copyWith(mode: mode, orderedNoteIds: ids),
          NoteOrderOperation(
            id: const Uuid().v4(),
            contextKey: context.key,
            type: NoteOrderOperationType.setMode,
            mode: mode,
            createdAt: DateTime.now().toUtc(),
          ),
        );
      });

  List<Note> sortNotes(NoteOrderContext context, Iterable<Note> notes) {
    final result = notes.toList();
    final current = snapshotFor(context);
    final positions = <String, int>{
      for (final entry in current.orderedNoteIds.indexed) entry.$2: entry.$1,
    };
    result.sort((a, b) => _compareNotes(a, b, current.mode, positions));
    return result;
  }

  Future<bool> reorderVisibleNotes({
    required NoteOrderContext context,
    required int draggedId,
    required int targetId,
    required bool placeAfter,
    required Iterable<Note> visibleNotes,
  }) => _mutateLatestSnapshot(context, (current) async {
    if (draggedId == targetId || !context.reorderable) return false;
    final visibleById = <int, Note>{
      for (final note in visibleNotes)
        if (note.id != null) note.id!: note,
    };
    final dragged = visibleById[draggedId];
    final target = visibleById[targetId];
    if (dragged == null || target == null) return false;
    if (dragged.pinned != target.pinned) {
      throw const PinnedSectionReorderException();
    }
    final draggedStableId = _stableId(dragged);
    final targetStableId = _stableId(target);
    if (draggedStableId == null || targetStableId == null) return false;

    final ids = current.orderedNoteIds.toList();
    final included = ids.toSet();
    for (final note in visibleNotes) {
      final stableId = _stableId(note);
      if (stableId != null && included.add(stableId)) ids.add(stableId);
    }
    ids.remove(draggedStableId);
    final targetIndex = ids.indexOf(targetStableId);
    if (targetIndex < 0) return false;
    ids.insert(targetIndex + (placeAfter ? 1 : 0), draggedStableId);
    if (listEquals(ids, current.orderedNoteIds)) return false;

    final movedIndex = ids.indexOf(draggedStableId);
    final afterId = movedIndex > 0 ? ids[movedIndex - 1] : null;
    final beforeId = movedIndex + 1 < ids.length ? ids[movedIndex + 1] : null;
    await _commit(
      current.copyWith(mode: NoteSortMode.custom, orderedNoteIds: ids),
      NoteOrderOperation(
        id: const Uuid().v4(),
        contextKey: context.key,
        type: NoteOrderOperationType.moveNote,
        noteId: draggedStableId,
        beforeId: beforeId,
        afterId: afterId,
        mode: NoteSortMode.custom,
        createdAt: DateTime.now().toUtc(),
      ),
    );
    return true;
  }, visibleNotes: visibleNotes);

  Future<bool> moveVisibleNote({
    required NoteOrderContext context,
    required int noteId,
    required int direction,
    required Iterable<Note> visibleNotes,
  }) async {
    if (direction == 0) return false;
    final sorted = sortNotes(context, visibleNotes);
    final currentIndex = sorted.indexWhere((note) => note.id == noteId);
    if (currentIndex < 0) return false;
    final current = sorted[currentIndex];
    final section = sorted
        .where((note) => note.pinned == current.pinned)
        .toList();
    final sectionIndex = section.indexWhere((note) => note.id == noteId);
    final targetIndex = sectionIndex + direction.sign;
    if (targetIndex < 0 || targetIndex >= section.length) return false;
    return reorderVisibleNotes(
      context: context,
      draggedId: noteId,
      targetId: section[targetIndex].id!,
      placeAfter: direction > 0,
      visibleNotes: visibleNotes,
    );
  }

  void beginDrag(NoteOrderContext context) {
    _activeDragContexts.add(context.key);
  }

  Future<void> endDrag(
    NoteOrderContext context, {
    required bool committed,
  }) async {
    _activeDragContexts.remove(context.key);
    final deferred = _deferredRemote.remove(context.key);
    if (!committed && deferred != null) {
      await _mutations.run(context.key, () => _applyOrRebaseRemote(deferred));
    }
  }

  int _compareNotes(
    Note a,
    Note b,
    NoteSortMode mode,
    Map<String, int> positions,
  ) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    switch (mode) {
      case NoteSortMode.custom:
        final positionA = a.syncId == null ? null : positions[a.syncId];
        final positionB = b.syncId == null ? null : positions[b.syncId];
        if (positionA == null && positionB != null) return -1;
        if (positionA != null && positionB == null) return 1;
        if (positionA != null && positionB != null) {
          final comparison = positionA.compareTo(positionB);
          if (comparison != 0) return comparison;
        }
        return _compareUpdatedNewest(a, b);
      case NoteSortMode.createdNewest:
        final created = _compareNullableDates(a.createdAt, b.createdAt);
        if (created != 0) return created;
        final updated = _compareNullableDates(a.updatedAt, b.updatedAt);
        if (updated != 0) return updated;
      case NoteSortMode.updatedNewest:
        return _compareUpdatedNewest(a, b);
    }
    return _compareIds(a.id, b.id);
  }

  int _compareUpdatedNewest(Note a, Note b) {
    final updated = _compareNullableDates(a.updatedAt, b.updatedAt);
    if (updated != 0) return updated;
    final created = _compareNullableDates(a.createdAt, b.createdAt);
    if (created != 0) return created;
    return _compareIds(a.id, b.id);
  }

  int _compareSeedOrder(Note a, Note b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    return _compareUpdatedNewest(a, b);
  }

  static int _compareNullableDates(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }

  static int _compareIds(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return b.compareTo(a);
  }

  String? _stableId(Note note) {
    final stableId = note.syncId;
    if (stableId != null && stableId.isNotEmpty) return stableId;
    return null;
  }

  static NoteSortMode _dateMode(NoteSortMode mode) =>
      mode == NoteSortMode.custom ? NoteSortMode.updatedNewest : mode;

  Future<void> _handleNoteEvent(NoteEvent event) async {
    if (!_initialized || event.origin != ModelChangeOrigin.local) return;
    final stableId = _stableId(event.note);
    if (stableId == null) return;
    try {
      for (final snapshot in snapshots.value.values.toList()) {
        final context = snapshot.context;
        if (!context.reorderable) continue;
        await _mutateLatestSnapshot(context, (current) async {
          if (event.event == 'deleted') {
            if (!current.orderedNoteIds.contains(stableId)) return;
            final ids = current.orderedNoteIds
                .where((candidate) => candidate != stableId)
                .toList();
            await _commit(
              current.copyWith(orderedNoteIds: ids),
              NoteOrderOperation(
                id: const Uuid().v4(),
                contextKey: context.key,
                type: NoteOrderOperationType.deleteNote,
                noteId: stableId,
                createdAt: DateTime.now().toUtc(),
              ),
            );
            return;
          }
          if ((event.event != 'created' && event.event != 'updated') ||
              current.orderedNoteIds.contains(stableId) ||
              !await _noteBelongsToContext(event.note, context)) {
            return;
          }
          await _commit(
            current.copyWith(
              orderedNoteIds: [stableId, ...current.orderedNoteIds],
            ),
            NoteOrderOperation(
              id: const Uuid().v4(),
              contextKey: context.key,
              type: NoteOrderOperationType.insertNote,
              noteId: stableId,
              createdAt: DateTime.now().toUtc(),
            ),
          );
        });
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        '[NOTE_SORT] Failed to process local note lifecycle',
        error,
        stackTrace,
      );
    }
  }

  @visibleForTesting
  Future<void> applyNoteEventForTesting(NoteEvent event) {
    return _handleNoteEvent(event);
  }

  Future<bool> _noteBelongsToContext(
    Note note,
    NoteOrderContext context,
  ) async {
    switch (context.kind) {
      case NoteOrderContextKind.main:
        return !note.archived && !note.trashed;
      case NoteOrderContextKind.pinnedFolder:
        return note.pinned && !note.archived && !note.trashed;
      case NoteOrderContextKind.labelFolder:
        if (context.scopeId == '__unlabeled__') {
          return (note.labels ?? '').trim().isEmpty;
        }
        final label = await Label.findBySyncId(context.scopeId!);
        if (label == null) return false;
        final labels = (note.labels ?? '')
            .split(',')
            .map((value) => value.trim())
            .toSet();
        return label.name.isEmpty
            ? labels.isEmpty
            : labels.contains(label.name);
      case NoteOrderContextKind.colorFolder:
        return note.color.toARGB32().toUnsigned(32).toString() ==
            context.scopeId;
      case NoteOrderContextKind.system:
        return false;
    }
  }

  Future<void> _commit(
    NoteOrderSnapshot draft,
    NoteOrderOperation operation,
  ) async {
    final next = draft.copyWith(
      revision: const Uuid().v4(),
      updatedAt: DateTime.now().toUtc(),
      dirty: true,
    );
    await AppState.db.transaction((txn) async {
      await _persistSnapshot(next, txn: txn);
      await txn.insert(
        operationTableName,
        operation.toDatabaseJson(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
    _publishSnapshot(next);
    _scheduleCloudWrite();
  }

  Future<void> _persistSnapshot(
    NoteOrderSnapshot value, {
    DatabaseExecutor? txn,
  }) async {
    final executor = txn ?? AppState.db;
    final row = value.toDatabaseJson();
    await executor.rawInsert(
      '''
      INSERT INTO $tableName (
        context_key, sort_mode, revision, base_revision,
        updated_at, dirty, hydrated
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(context_key) DO UPDATE SET
        sort_mode = excluded.sort_mode,
        revision = excluded.revision,
        base_revision = excluded.base_revision,
        updated_at = excluded.updated_at,
        dirty = excluded.dirty,
        hydrated = excluded.hydrated
      ''',
      [
        row['context_key'],
        row['sort_mode'],
        row['revision'],
        row['base_revision'],
        row['updated_at'],
        row['dirty'],
        row['hydrated'],
      ],
    );
    await executor.delete(
      positionTableName,
      where: 'context_key = ?',
      whereArgs: [value.context.key],
    );
    for (final entry in value.orderedNoteIds.indexed) {
      await executor.insert(positionTableName, {
        'context_key': value.context.key,
        'note_sync_id': entry.$2,
        'position': entry.$1,
      });
    }
  }

  void _publishSnapshot(NoteOrderSnapshot snapshot) {
    snapshots.value = Map.unmodifiable({
      ...snapshots.value,
      snapshot.context.key: snapshot,
    });
  }

  Future<List<NoteOrderOperation>> _loadOperations(String contextKey) async {
    final rows = await AppState.db.query(
      operationTableName,
      where: 'context_key = ?',
      whereArgs: [contextKey],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows
        .map(NoteOrderOperation.tryFromDatabaseJson)
        .whereType<NoteOrderOperation>()
        .toList();
  }

  Future<void> startCloudSync() async {
    await init();
    if (_cloudInitialized || !_canReceiveCloud) return;
    _cloudInitialized = true;
    PlanService.instance.statusNotifier.addListener(_handlePlanChange);

    unawaited(
      _remoteHydration.ready.then((_) async {
        if (!_cloudInitialized) return;
        _remoteInitialResolved = true;
        await _tryFinishBootstrap();
      }),
    );
    _startContextListener();

    unawaited(
      Future.wait([
        NoteSyncService().initialHydration,
        LabelSyncService().initialHydration,
      ]).then((_) async {
        if (!_cloudInitialized) return;
        _dataHydrated = true;
        await _tryFinishBootstrap();
      }),
    );
  }

  void _startContextListener() {
    unawaited(_remoteListener?.cancel());
    _remoteListener = null;
    if (!_cloudInitialized || !_canReceiveCloud) return;
    final hydrationGeneration = _remoteHydration.startAttempt();
    _remoteListener = _contextCollectionRef
        .snapshots(includeMetadataChanges: true)
        .listen(
          (query) async {
            _remoteHydration.beginWork(
              hydrationGeneration,
              isFromCache: query.metadata.isFromCache,
            );
            var hydrationFailed = false;
            try {
              for (final document in query.docs) {
                if (document.metadata.hasPendingWrites) continue;
                final remote = await _decodeRemoteDocument(document);
                if (remote == null) continue;
                _remoteContextKeys.add(remote.context.key);
                _remoteChunkCounts[remote.revision] =
                    document.data()['chunk_count'] as int;
                await _mutations.run(
                  remote.context.key,
                  () => _receiveRemote(remote),
                );
              }
            } catch (error, stackTrace) {
              hydrationFailed = true;
              AppLogger.error(
                '[NOTE_SORT] Failed to apply initial context snapshot',
                error,
                stackTrace,
              );
            } finally {
              _remoteHydration.endWork(
                hydrationGeneration,
                failed: hydrationFailed,
              );
              if (hydrationFailed) {
                _restartContextListenerAfterFailure(hydrationGeneration);
              } else if (_remoteHydration.isReady) {
                _remoteListenerRetry.succeeded();
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error(
              '[NOTE_SORT] Context listener failed',
              error,
              stackTrace,
            );
            _remoteHydration.failAttempt(hydrationGeneration);
            _restartContextListenerAfterFailure(hydrationGeneration);
          },
        );
  }

  void _restartContextListenerAfterFailure(int generation) {
    if (!_remoteHydration.isCurrent(generation)) return;
    _remoteListenerRetry.schedule(() {
      if (_cloudInitialized && _canReceiveCloud) {
        AppLogger.log('[NOTE_SORT] Restarting context listener after failure');
        _startContextListener();
      }
    });
  }

  Future<void> _tryFinishBootstrap() async {
    if (!_cloudInitialized ||
        !_remoteInitialResolved ||
        !_dataHydrated ||
        _bootstrapReady) {
      return;
    }
    _bootstrapReady = true;
    await _migrateLegacyCloudIfNeeded();
    await _drainCloudCleanup();
    _scheduleCloudWrite();
  }

  Future<NoteOrderSnapshot?> _decodeRemoteDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) async {
    final data = document.data();
    if (data == null) return null;
    return _decodeRemoteData(document.id, data);
  }

  Future<NoteOrderSnapshot?> _decodeRemoteData(
    String documentId,
    Map<String, dynamic> data,
  ) async {
    if (data['schema_version'] != cloudSchemaVersion) {
      return null;
    }
    final contextKey = data['context_key'];
    final revision = data['revision'];
    final modeName = data['sort_mode'];
    final chunkCount = data['chunk_count'];
    final noteCount = data['note_count'];
    if (contextKey is! String ||
        documentId != contextKey ||
        revision is! String ||
        revision.isEmpty ||
        modeName is! String ||
        chunkCount is! int ||
        chunkCount < 0 ||
        chunkCount > maxCloudChunks ||
        noteCount is! int ||
        noteCount < 0) {
      return null;
    }
    final context = NoteOrderContext.tryParse(contextKey);
    final mode = NoteSortMode.values
        .where((candidate) => candidate.name == modeName)
        .firstOrNull;
    if (context == null || mode == null) return null;

    final chunks = await _cloudRepository.readChunks(revision, chunkCount);
    if (chunks == null) return null;
    final ids = decodeCloudChunks(
      revision: revision,
      noteCount: noteCount,
      chunkCount: chunkCount,
      chunks: chunks,
    );
    if (ids == null) return null;
    final timestamp = data['updated_at'];
    return NoteOrderSnapshot(
      context: context,
      mode: context.reorderable ? mode : _dateMode(mode),
      orderedNoteIds: ids,
      revision: revision,
      baseRevision: revision,
      updatedAt: timestamp is Timestamp
          ? timestamp.toDate().toUtc()
          : DateTime.now().toUtc(),
      hydrated: true,
    );
  }

  Future<void> _receiveRemote(NoteOrderSnapshot remote) async {
    if (_activeDragContexts.contains(remote.context.key)) {
      _deferredRemote[remote.context.key] = remote;
      return;
    }
    await _applyOrRebaseRemote(remote);
  }

  @visibleForTesting
  Future<void> applyRemoteSnapshotForTesting(NoteOrderSnapshot remote) {
    return _mutations.run(
      remote.context.key,
      () => _applyOrRebaseRemote(remote),
    );
  }

  Future<void> _applyOrRebaseRemote(NoteOrderSnapshot remote) async {
    final local = snapshots.value[remote.context.key];
    if (local?.revision == remote.revision && local?.dirty == false) return;
    final operations = await _loadOperations(remote.context.key);
    if (operations.isEmpty) {
      await _persistSnapshot(remote);
      _publishSnapshot(remote);
      return;
    }

    var mode = remote.mode;
    final ids = remote.orderedNoteIds.toList();
    for (final operation in operations) {
      switch (operation.type) {
        case NoteOrderOperationType.setMode:
          mode = operation.mode ?? mode;
        case NoteOrderOperationType.insertNote:
          final noteId = operation.noteId;
          if (noteId != null && !ids.contains(noteId)) ids.insert(0, noteId);
        case NoteOrderOperationType.deleteNote:
          ids.remove(operation.noteId);
        case NoteOrderOperationType.moveNote:
          final noteId = operation.noteId;
          if (noteId == null) continue;
          ids.remove(noteId);
          final beforeIndex = operation.beforeId == null
              ? -1
              : ids.indexOf(operation.beforeId!);
          final afterIndex = operation.afterId == null
              ? -1
              : ids.indexOf(operation.afterId!);
          if (beforeIndex >= 0) {
            ids.insert(beforeIndex, noteId);
          } else if (afterIndex >= 0) {
            ids.insert(afterIndex + 1, noteId);
          } else {
            ids.add(noteId);
          }
          mode = operation.mode ?? mode;
      }
    }
    final rebased = NoteOrderSnapshot(
      context: remote.context,
      mode: mode,
      orderedNoteIds: List.unmodifiable(ids),
      revision: const Uuid().v4(),
      baseRevision: remote.revision,
      updatedAt: DateTime.now().toUtc(),
      dirty: true,
      hydrated: true,
    );
    await _persistSnapshot(rebased);
    _publishSnapshot(rebased);
    _scheduleCloudWrite();
  }

  void _handlePlanChange() {
    if (_canPushCloud) _scheduleCloudWrite();
  }

  void _scheduleCloudWrite() {
    _cloudWriteTimer?.cancel();
    if (!_cloudInitialized || !_bootstrapReady || !_canPushCloud) return;
    _cloudWriteTimer = Timer(_cloudDebounce, () {
      final upload = _uploadDirtyContexts();
      _activeUpload = upload;
      unawaited(
        upload.whenComplete(() {
          if (identical(_activeUpload, upload)) _activeUpload = null;
        }),
      );
    });
  }

  Future<void> _uploadDirtyContexts() async {
    if (!_canPushCloud || !_bootstrapReady) return;
    if (_uploading) {
      _uploadAgain = true;
      return;
    }
    _uploading = true;
    try {
      for (final snapshot in snapshots.value.values.toList()) {
        if (!snapshot.dirty) continue;
        await _uploadSnapshot(snapshot);
      }
    } finally {
      _uploading = false;
      if (_uploadAgain) {
        _uploadAgain = false;
        _scheduleCloudWrite();
      }
    }
  }

  Future<void> _uploadSnapshot(NoteOrderSnapshot local) async {
    final chunks = chunkNoteIds(local.orderedNoteIds);
    try {
      await _journalCloudRevision(
        contextKey: local.context.key,
        revision: local.revision,
        chunkCount: chunks.length,
      );
      await _cloudRepository.writeChunks(local.revision, chunks);
      final commit = await _cloudRepository.commitManifest(
        contextKey: local.context.key,
        sortMode: local.mode.name,
        revision: local.revision,
        baseRevision: local.baseRevision,
        chunkCount: chunks.length,
        noteCount: local.orderedNoteIds.length,
      );
      await _clearCloudCleanup(local.revision);

      final currentLocal = snapshots.value[local.context.key];
      if (currentLocal?.revision == local.revision) {
        final clean = local.copyWith(
          baseRevision: local.revision,
          dirty: false,
          hydrated: true,
        );
        await AppState.db.transaction((txn) async {
          await _persistSnapshot(clean, txn: txn);
          await txn.delete(
            operationTableName,
            where: 'context_key = ?',
            whereArgs: [local.context.key],
          );
        });
        _publishSnapshot(clean);
      }
      _remoteContextKeys.add(local.context.key);
      _remoteChunkCounts[local.revision] = chunks.length;
      final previousRevision = commit.previousRevision;
      if (previousRevision != null && previousRevision != local.revision) {
        await _journalCloudRevision(
          contextKey: local.context.key,
          revision: previousRevision,
          chunkCount: commit.previousChunkCount,
        );
        unawaited(_drainCloudCleanup());
      }
    } on NoteSortRevisionConflict {
      await _cleanupCloudRevision(
        contextKey: local.context.key,
        revision: local.revision,
        chunkCount: chunks.length,
      );
      final remote = await _readRemoteSnapshot(local.context.key);
      if (remote != null) {
        await _mutations.run(
          local.context.key,
          () => _applyOrRebaseRemote(remote),
        );
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        '[NOTE_SORT] Failed to upload ${local.context.key}',
        error,
        stackTrace,
      );
      await _cleanupCloudRevision(
        contextKey: local.context.key,
        revision: local.revision,
        chunkCount: chunks.length,
      );
    }
  }

  Future<NoteOrderSnapshot?> _readRemoteSnapshot(String contextKey) async {
    final data = await _cloudRepository.readManifest(contextKey);
    if (data == null) return null;
    return _decodeRemoteData(contextKey, data);
  }

  Future<void> _journalCloudRevision({
    required String contextKey,
    required String revision,
    required int chunkCount,
  }) async {
    await AppState.db.insert(cleanupTableName, {
      'revision': revision,
      'context_key': contextKey,
      'chunk_count': chunkCount,
      'retry_count': 0,
      'next_retry_at': null,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _clearCloudCleanup(String revision) async {
    await AppState.db.delete(
      cleanupTableName,
      where: 'revision = ?',
      whereArgs: [revision],
    );
  }

  Future<void> _cleanupCloudRevision({
    required String contextKey,
    required String revision,
    required int chunkCount,
  }) async {
    try {
      final manifest = await _cloudRepository.readManifest(contextKey);
      if (manifest?['revision'] != revision) {
        await _cloudRepository.deleteRevision(revision, chunkCount);
      }
      await _clearCloudCleanup(revision);
    } catch (error, stackTrace) {
      await _recordCloudCleanupFailure(revision);
      AppLogger.error(
        '[NOTE_SORT] Failed to remove unreferenced order chunks',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _recordCloudCleanupFailure(String revision) async {
    final rows = await AppState.db.query(
      cleanupTableName,
      columns: ['retry_count'],
      where: 'revision = ?',
      whereArgs: [revision],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final retryCount = (rows.first['retry_count'] as int? ?? 0) + 1;
    final exponent = min(retryCount - 1, 6);
    final seconds = min(300, 1 << exponent);
    await AppState.db.update(
      cleanupTableName,
      {
        'retry_count': retryCount,
        'next_retry_at': DateTime.now()
            .toUtc()
            .add(Duration(seconds: seconds))
            .toIso8601String(),
      },
      where: 'revision = ?',
      whereArgs: [revision],
    );
    _scheduleCloudCleanup(Duration(seconds: seconds));
  }

  Future<void> _drainCloudCleanup() async {
    if (_cleanupRunning || !_canReceiveCloud) return;
    _cleanupRunning = true;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final rows = await AppState.db.query(
        cleanupTableName,
        where: 'next_retry_at IS NULL OR next_retry_at <= ?',
        whereArgs: [now],
        orderBy: 'created_at ASC',
      );
      for (final row in rows) {
        final contextKey = row['context_key'];
        final revision = row['revision'];
        final chunkCount = row['chunk_count'];
        if (contextKey is! String ||
            revision is! String ||
            chunkCount is! int ||
            chunkCount < 0 ||
            chunkCount > maxCloudChunks) {
          if (revision is String) await _clearCloudCleanup(revision);
          continue;
        }
        await _cleanupCloudRevision(
          contextKey: contextKey,
          revision: revision,
          chunkCount: chunkCount,
        );
      }
      await _scheduleNextCloudCleanup();
    } finally {
      _cleanupRunning = false;
    }
  }

  Future<void> _scheduleNextCloudCleanup() async {
    final rows = await AppState.db.query(
      cleanupTableName,
      columns: ['next_retry_at'],
      where: 'next_retry_at IS NOT NULL',
      orderBy: 'next_retry_at ASC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    final next = DateTime.tryParse(
      rows.first['next_retry_at'] as String? ?? '',
    );
    if (next == null) return;
    final delay = next.difference(DateTime.now().toUtc());
    _scheduleCloudCleanup(delay.isNegative ? Duration.zero : delay);
  }

  void _scheduleCloudCleanup(Duration delay) {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer(delay, () => unawaited(_drainCloudCleanup()));
  }

  @visibleForTesting
  Future<void> drainCloudCleanupForTesting() => _drainCloudCleanup();

  @visibleForTesting
  Future<void> uploadSnapshotForTesting(NoteOrderSnapshot snapshot) {
    return _uploadSnapshot(snapshot);
  }

  Future<void> _migrateLegacyCloudIfNeeded() async {
    if (_legacyMigrationAttempted) return;
    _legacyMigrationAttempted = true;
    try {
      final manifest = await _legacyManifestRef.get();
      final data = manifest.data();
      if (!manifest.exists ||
          data == null ||
          data['schema_version'] != legacyCloudSchemaVersion) {
        return;
      }
      final revision = data['revision'];
      final modeName = data['sort_mode'];
      final chunkCount = data['chunk_count'];
      final noteCount = data['note_count'];
      if (revision is! String ||
          modeName is! String ||
          chunkCount is! int ||
          noteCount is! int ||
          chunkCount < 0 ||
          chunkCount > maxCloudChunks) {
        return;
      }
      final mode = NoteSortMode.values
          .where((candidate) => candidate.name == modeName)
          .firstOrNull;
      if (mode == null) return;
      final chunks = <Map<String, dynamic>>[];
      for (var index = 0; index < chunkCount; index++) {
        final chunk = await _legacyChunkRef(revision, index).get();
        final payload = chunk.data();
        if (!chunk.exists || payload == null) return;
        chunks.add(payload);
      }
      final localIds = decodeLegacyCloudChunks(
        revision: revision,
        noteCount: noteCount,
        chunkCount: chunkCount,
        chunks: chunks,
      );
      if (localIds == null) return;
      final placeholders = List.filled(localIds.length, '?').join(',');
      final rows = localIds.isEmpty
          ? const <Map<String, Object?>>[]
          : await AppState.db.rawQuery(
              'SELECT id, sync_id FROM note WHERE id IN ($placeholders)',
              localIds,
            );
      final byLocalId = <int, String>{
        for (final row in rows)
          if (row['id'] is int && row['sync_id'] is String)
            row['id'] as int: row['sync_id'] as String,
      };
      final stableOrder = [
        for (final id in localIds)
          if (byLocalId[id] != null) byLocalId[id]!,
      ];
      final notes = await Note.get(NoteType.all);
      final contexts = <NoteOrderContext>[
        const NoteOrderContext.mainGrid(),
        const NoteOrderContext.mainList(),
        const NoteOrderContext.pinned(),
        NoteOrderContext.label('__unlabeled__'),
        for (final label in await Label.get())
          if (label.syncId != null) NoteOrderContext.label(label.syncId!),
        for (final color in await Note.getAllColors())
          NoteOrderContext.color(color.value.toARGB32()),
      ];
      for (final context in contexts) {
        if (_remoteContextKeys.contains(context.key)) continue;
        if ((await _loadOperations(context.key)).isNotEmpty) continue;
        final matchingIds = <String>{};
        for (final note in notes) {
          if (await _noteBelongsToContext(note, context)) {
            final stableId = _stableId(note);
            if (stableId != null) matchingIds.add(stableId);
          }
        }
        final filtered = stableOrder
            .where(matchingIds.contains)
            .toList(growable: true);
        for (final id in matchingIds) {
          if (!filtered.contains(id)) filtered.add(id);
        }
        final migrated = NoteOrderSnapshot(
          context: context,
          mode: context.reorderable ? mode : _dateMode(mode),
          orderedNoteIds: filtered,
          revision: const Uuid().v4(),
          updatedAt: DateTime.now().toUtc(),
          dirty: true,
          hydrated: true,
        );
        await _persistSnapshot(migrated);
        _publishSnapshot(migrated);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        '[NOTE_SORT] Legacy cloud migration failed safely',
        error,
        stackTrace,
      );
    }
  }

  @visibleForTesting
  static List<List<String>> chunkNoteIds(List<String> ids) {
    if (ids.isEmpty) return const [];
    return [
      for (var start = 0; start < ids.length; start += cloudChunkSize)
        List<String>.unmodifiable(
          ids.sublist(
            min(start, ids.length),
            min(start + cloudChunkSize, ids.length),
          ),
        ),
    ];
  }

  @visibleForTesting
  static List<String>? decodeCloudChunks({
    required String revision,
    required int noteCount,
    required int chunkCount,
    required List<Map<String, dynamic>> chunks,
  }) {
    if (chunkCount < 0 ||
        chunkCount > maxCloudChunks ||
        chunks.length != chunkCount) {
      return null;
    }
    final ids = <String>[];
    final seen = <String>{};
    for (final chunk in chunks) {
      if (chunk['schema_version'] != cloudSchemaVersion ||
          chunk['revision'] != revision ||
          chunk['note_ids'] is! List) {
        return null;
      }
      final values = chunk['note_ids'] as List;
      if (values.length > cloudChunkSize) return null;
      for (final value in values) {
        if (value is! String || value.isEmpty || !seen.add(value)) return null;
        ids.add(value);
      }
    }
    return ids.length == noteCount ? List.unmodifiable(ids) : null;
  }

  @visibleForTesting
  static List<int>? decodeLegacyCloudChunks({
    required String revision,
    required int noteCount,
    required int chunkCount,
    required List<Map<String, dynamic>> chunks,
  }) {
    if (chunkCount < 0 ||
        chunkCount > maxCloudChunks ||
        chunks.length != chunkCount) {
      return null;
    }
    final ids = <int>[];
    final seen = <int>{};
    for (final chunk in chunks) {
      if (chunk['schema_version'] != legacyCloudSchemaVersion ||
          chunk['revision'] != revision ||
          chunk['note_ids'] is! List) {
        return null;
      }
      final values = chunk['note_ids'] as List;
      if (values.length > cloudChunkSize) return null;
      for (final value in values) {
        if (value is! int || value <= 0 || !seen.add(value)) return null;
        ids.add(value);
      }
    }
    return ids.length == noteCount ? List.unmodifiable(ids) : null;
  }

  Future<void> dispose() async {
    Note.off('changed', _handleNoteEvent);
    PlanService.instance.statusNotifier.removeListener(_handlePlanChange);
    _cloudWriteTimer?.cancel();
    _cloudWriteTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    await _remoteListener?.cancel();
    _remoteListener = null;
    _remoteListenerRetry.cancel();
    _remoteHydration.reset();
    final upload = _activeUpload;
    if (upload != null) {
      try {
        await upload.timeout(const Duration(seconds: 5));
      } catch (error) {
        AppLogger.error('[NOTE_SORT] Pending upload did not finish', error);
      }
    }
    _activeUpload = null;
    _firestoreInstance = null;
    _cloudRepositoryInstance = null;
    _initialized = false;
    _cloudInitialized = false;
    _remoteInitialResolved = false;
    _dataHydrated = false;
    _bootstrapReady = false;
    _legacyMigrationAttempted = false;
    _uploading = false;
    _uploadAgain = false;
    _cleanupRunning = false;
    _activeDragContexts.clear();
    _deferredRemote.clear();
    _remoteChunkCounts.clear();
    _remoteContextKeys.clear();
    snapshots.value = const {};
  }
}
