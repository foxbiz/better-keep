import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/initial_hydration_gate.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/note_sort_cloud_repository.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/services/retry_controller.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
  static const NoteSortMode defaultHomeSortMode = NoteSortMode.custom;

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
  static bool? e2eeReadyOverride;

  @visibleForTesting
  static Future<void> Function()? cloudStartOverride;

  @visibleForTesting
  static NoteSortCloudRepository? cloudRepositoryOverride;

  @visibleForTesting
  static Duration Function(int attempt)? uploadRetryDelayOverride;

  @visibleForTesting
  static Duration? disposeTimeoutOverride;

  final ValueNotifier<Map<String, NoteOrderSnapshot>> snapshots = ValueNotifier(
    const {},
  );
  final AsyncKeyedSerializer<String> _mutations = AsyncKeyedSerializer();
  final AsyncKeyedSerializer<int> _remoteEvents = AsyncKeyedSerializer();
  final Set<Future<dynamic>> _cloudTasks = {};

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _remoteListener;
  Timer? _cloudWriteTimer;
  Future<void>? _activeUpload;
  Timer? _cleanupTimer;
  bool _initialized = false;
  bool _lastKnownCryptoReady = false;
  final InitialHydrationGate _remoteHydration = InitialHydrationGate();
  final HydrationRetryController _remoteListenerRetry =
      HydrationRetryController();
  int _nextCloudGeneration = 0;
  _NoteSortCloudRun? _cloudRun;
  final Set<String> _activeDragContexts = {};
  final Map<String, NoteOrderSnapshot> _deferredRemote = {};
  final Map<String, int> _remoteChunkCounts = {};
  final Set<String> _remoteContextKeys = {};

  FirebaseFirestore get _firestore => FirebaseBackend.firestore;

  CollectionReference<Map<String, dynamic>> _contextCollectionRef(
    _NoteSortCloudSession session,
  ) => session.firestore!
      .collection('users')
      .doc(session.userId)
      .collection(_contextCollection);

  DocumentReference<Map<String, dynamic>> _legacyManifestRef(
    _NoteSortCloudSession session,
  ) => session.firestore!
      .collection('users')
      .doc(session.userId)
      .collection(_legacyManifestCollection)
      .doc(_legacyManifestDocument);

  DocumentReference<Map<String, dynamic>> _legacyChunkRef(
    _NoteSortCloudSession session,
    String revision,
    int index,
  ) => session.firestore!
      .collection('users')
      .doc(session.userId)
      .collection(_legacySnapshotCollection)
      .doc(revision)
      .collection('chunks')
      .doc(index.toString().padLeft(6, '0'));

  bool get _canReceiveCloud {
    if (!_isCryptoReady) {
      return false;
    }
    if (canReceiveCloudOverride != null) return canReceiveCloudOverride!;
    try {
      final user = AuthService.currentUser;
      return user != null &&
          !AuthService.sessionInvalid.value &&
          !ReviewAccess.isAuthorizedSessionFor(user);
    } catch (_) {
      return false;
    }
  }

  bool get _isCryptoReady =>
      e2eeReadyOverride ?? E2EEService.instance.isCryptoReady;

  bool get _canPushCloud =>
      canPushCloudOverride ?? (_canReceiveCloud && PlanService.instance.isPaid);

  bool _isCurrentCloudRun(_NoteSortCloudRun run) => identical(_cloudRun, run);

  Future<T> _trackCloudTask<T>(Future<T> task) {
    _cloudTasks.add(task);
    unawaited(
      task.then<void>(
        (_) => _cloudTasks.remove(task),
        onError: (Object _, StackTrace _) => _cloudTasks.remove(task),
      ),
    );
    return task;
  }

  _NoteSortCloudRun _newCloudRun({
    required String userId,
    required Database database,
    required FirebaseFirestore? firestore,
    required NoteSortCloudRepository repository,
  }) {
    final session = _NoteSortCloudSession(
      generation: ++_nextCloudGeneration,
      userId: userId,
      database: database,
      firestore: firestore,
      repository: repository,
    );
    return _NoteSortCloudRun(
      session: session,
      uploadRetry: ExponentialBackoffRetryController(
        maxDelay: const Duration(minutes: 5),
        delayForAttempt: uploadRetryDelayOverride,
      ),
    );
  }

  _NoteSortCloudRun _cloudRunForTesting() {
    final existing = _cloudRun;
    final repository = cloudRepositoryOverride;
    if (repository == null) {
      throw StateError('A cloudRepositoryOverride is required for this test');
    }
    if (existing != null &&
        identical(existing.session.database, AppState.db) &&
        identical(existing.session.repository, repository)) {
      return existing;
    }
    final run = _newCloudRun(
      userId: 'test-user',
      database: AppState.db,
      firestore: null,
      repository: repository,
    );
    run.bootstrapReady = true;
    _cloudRun = run;
    return run;
  }

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
          'sort_mode': (mode ?? defaultHomeSortMode).name,
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
    _lastKnownCryptoReady = _isCryptoReady;
    E2EEService.instance.status.addListener(_handleE2EEStatusChange);
    E2EEService.instance.deviceManager.hasUMK.addListener(
      _handleE2EEStatusChange,
    );
  }

  void _handleE2EEStatusChange() {
    final isNowReady = _isCryptoReady;
    final wasReady = _lastKnownCryptoReady;
    _lastKnownCryptoReady = isNowReady;
    if (isNowReady == wasReady) return;

    if (isNowReady) {
      unawaited(
        startCloudSync().catchError((Object error, StackTrace stackTrace) {
          AppLogger.error(
            '[NOTE_SORT] Failed to start cloud sync after E2EE became ready',
            error,
            stackTrace,
          );
        }),
      );
      return;
    }

    unawaited(
      _stopCloudSync().catchError((Object error, StackTrace stackTrace) {
        AppLogger.error(
          '[NOTE_SORT] Failed to stop cloud sync after E2EE became unavailable',
          error,
          stackTrace,
        );
      }),
    );
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

  static NoteSortMode defaultSortModeFor(NoteOrderContext context) =>
      context.kind == NoteOrderContextKind.main
      ? defaultHomeSortMode
      : NoteSortMode.updatedNewest;

  NoteOrderSnapshot _defaultSnapshot(NoteOrderContext context) =>
      NoteOrderSnapshot(
        context: context,
        mode: defaultSortModeFor(context),
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
    final legacyMode = await _legacyMode(context);
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

  Future<NoteSortMode> _legacyMode(NoteOrderContext context) async {
    final defaultMode = defaultSortModeFor(context);
    final rows = await AppState.db.query(legacyTableName, limit: 1);
    if (rows.isEmpty) return defaultMode;
    final name = rows.first['sort_mode'] as String?;
    return NoteSortMode.values
            .where((candidate) => candidate.name == name)
            .firstOrNull ??
        defaultMode;
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
    if (deferred != null) {
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
    NoteOrderContext context, {
    DatabaseExecutor? database,
  }) async {
    switch (context.kind) {
      case NoteOrderContextKind.main:
        return !note.archived && !note.trashed;
      case NoteOrderContextKind.pinnedFolder:
        return note.pinned && !note.archived && !note.trashed;
      case NoteOrderContextKind.labelFolder:
        if (context.scopeId == '__unlabeled__') {
          return (note.labels ?? '').trim().isEmpty;
        }
        final labelRows = await (database ?? AppState.db).query(
          Label.model,
          columns: ['name'],
          where: 'sync_id = ?',
          whereArgs: [context.scopeId],
          limit: 1,
        );
        if (labelRows.isEmpty) return false;
        final labelName = labelRows.first['name'] as String? ?? '';
        final labels = (note.labels ?? '')
            .split(',')
            .map((value) => value.trim())
            .toSet();
        return labelName.isEmpty ? labels.isEmpty : labels.contains(labelName);
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
    DatabaseExecutor? database,
  }) async {
    final executor = txn ?? database ?? AppState.db;
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

  Future<List<NoteOrderOperation>> _loadOperations(
    String contextKey, {
    DatabaseExecutor? database,
  }) async {
    final rows = await (database ?? AppState.db).query(
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
    if (!_initialized) return;
    if (_cloudRun != null || !_canReceiveCloud) return;
    final startOverride = cloudStartOverride;
    if (startOverride != null) {
      await startOverride();
      return;
    }
    final user = AuthService.currentUser;
    if (user == null) return;
    final firestore = _firestore;
    final repository =
        cloudRepositoryOverride ??
        FirestoreNoteSortCloudRepository(
          firestore: firestore,
          userId: user.uid,
          schemaVersion: cloudSchemaVersion,
        );
    final run = _newCloudRun(
      userId: user.uid,
      database: AppState.db,
      firestore: firestore,
      repository: repository,
    );
    _cloudRun = run;
    PlanService.instance.statusNotifier.addListener(_handlePlanChange);

    unawaited(
      _remoteHydration.ready.then<void>((_) async {
        if (!_isCurrentCloudRun(run)) return;
        try {
          run.remoteInitialResolved = true;
          await _tryFinishBootstrap(run);
        } catch (error, stackTrace) {
          if (_isCurrentCloudRun(run)) {
            AppLogger.error(
              '[NOTE_SORT] Remote hydration failed before cloud bootstrap',
              error,
              stackTrace,
            );
          }
        }
      }),
    );
    _startContextListener(run);

    unawaited(
      Future.wait([
        NoteSyncService().initialHydration,
        LabelSyncService().initialHydration,
      ]).then<void>(
        (_) async {
          if (!_isCurrentCloudRun(run)) return;
          try {
            run.dataHydrated = true;
            await _tryFinishBootstrap(run);
          } catch (error, stackTrace) {
            if (_isCurrentCloudRun(run)) {
              AppLogger.error(
                '[NOTE_SORT] Data hydration failed before cloud bootstrap',
                error,
                stackTrace,
              );
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (_isCurrentCloudRun(run)) {
            AppLogger.error(
              '[NOTE_SORT] Data hydration failed before cloud bootstrap',
              error,
              stackTrace,
            );
          }
        },
      ),
    );
  }

  void _startContextListener(_NoteSortCloudRun run) {
    unawaited(_remoteListener?.cancel());
    _remoteListener = null;
    if (!_isCurrentCloudRun(run) || !_canReceiveCloud) return;
    final hydrationGeneration = _remoteHydration.startAttempt();
    _remoteListener = _contextCollectionRef(run.session)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (query) {
            if (!_isCurrentCloudRun(run) ||
                !_remoteHydration.isCurrent(hydrationGeneration)) {
              return;
            }
            _remoteHydration.beginWork(
              hydrationGeneration,
              isFromCache: query.metadata.isFromCache,
            );
            final work = _remoteEvents.run(
              hydrationGeneration,
              () => _processContextSnapshot(run, hydrationGeneration, query),
            );
            _trackCloudTask(work);
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error(
              '[NOTE_SORT] Context listener failed',
              error,
              stackTrace,
            );
            _failContextListenerAttempt(run, hydrationGeneration);
          },
        );
  }

  Future<void> _processContextSnapshot(
    _NoteSortCloudRun run,
    int hydrationGeneration,
    QuerySnapshot<Map<String, dynamic>> query,
  ) async {
    var hydrationFailed = false;
    try {
      if (!_isCurrentCloudRun(run) ||
          !_remoteHydration.isCurrent(hydrationGeneration)) {
        return;
      }
      for (final document in query.docs) {
        if (!_isCurrentCloudRun(run) ||
            !_remoteHydration.isCurrent(hydrationGeneration)) {
          return;
        }
        if (document.metadata.hasPendingWrites) continue;
        final remote = await _decodeRemoteDocument(run, document);
        if (!_isCurrentCloudRun(run) ||
            !_remoteHydration.isCurrent(hydrationGeneration)) {
          return;
        }
        if (remote == null) continue;
        _remoteContextKeys.add(remote.context.key);
        _remoteChunkCounts[remote.revision] =
            document.data()['chunk_count'] as int;
        await _mutations.run(
          remote.context.key,
          () => _receiveRemote(run, remote),
        );
      }
    } catch (error, stackTrace) {
      hydrationFailed = true;
      AppLogger.error(
        '[NOTE_SORT] Failed to apply context snapshot',
        error,
        stackTrace,
      );
    } finally {
      _remoteHydration.endWork(hydrationGeneration, failed: hydrationFailed);
      if (hydrationFailed) {
        _failContextListenerAttempt(run, hydrationGeneration);
      } else if (_remoteHydration.isReady) {
        _remoteListenerRetry.succeeded();
      }
    }
  }

  void _failContextListenerAttempt(_NoteSortCloudRun run, int generation) {
    if (!_isCurrentCloudRun(run) || !_remoteHydration.isCurrent(generation)) {
      return;
    }
    _remoteHydration.failAttempt(generation);
    _remoteHydration.invalidateAttempt();
    final listener = _remoteListener;
    _remoteListener = null;
    if (listener != null) _trackCloudTask(listener.cancel());
    _remoteListenerRetry.schedule(() {
      if (_isCurrentCloudRun(run) && _canReceiveCloud) {
        AppLogger.log('[NOTE_SORT] Restarting context listener after failure');
        _startContextListener(run);
      }
    });
  }

  Future<void> _tryFinishBootstrap(_NoteSortCloudRun run) async {
    if (!_isCurrentCloudRun(run) ||
        !run.remoteInitialResolved ||
        !run.dataHydrated ||
        run.bootstrapReady) {
      return;
    }
    run.bootstrapReady = true;
    await _migrateLegacyCloudIfNeeded(run);
    if (!_isCurrentCloudRun(run)) return;
    await _drainCloudCleanup(run);
    if (!_isCurrentCloudRun(run)) return;
    _scheduleCloudWrite(run);
  }

  Future<NoteOrderSnapshot?> _decodeRemoteDocument(
    _NoteSortCloudRun run,
    DocumentSnapshot<Map<String, dynamic>> document,
  ) async {
    final data = document.data();
    if (data == null) return null;
    return _decodeRemoteData(run, document.id, data);
  }

  Future<NoteOrderSnapshot?> _decodeRemoteData(
    _NoteSortCloudRun run,
    String documentId,
    Map<String, dynamic> data,
  ) async {
    if (!_isCurrentCloudRun(run)) return null;
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

    final chunks = await run.session.repository.readChunks(
      revision,
      chunkCount,
    );
    if (!_isCurrentCloudRun(run)) return null;
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

  Future<void> _receiveRemote(
    _NoteSortCloudRun run,
    NoteOrderSnapshot remote,
  ) async {
    if (!_isCurrentCloudRun(run)) return;
    if (_activeDragContexts.contains(remote.context.key)) {
      _deferredRemote[remote.context.key] = remote;
      return;
    }
    await _applyOrRebaseRemote(remote, run: run);
  }

  @visibleForTesting
  Future<void> applyRemoteSnapshotForTesting(NoteOrderSnapshot remote) {
    return _mutations.run(
      remote.context.key,
      () => _applyOrRebaseRemote(remote),
    );
  }

  @visibleForTesting
  Future<void> receiveRemoteSnapshotForTesting(NoteOrderSnapshot remote) {
    return _mutations.run(remote.context.key, () async {
      if (_activeDragContexts.contains(remote.context.key)) {
        _deferredRemote[remote.context.key] = remote;
        return;
      }
      await _applyOrRebaseRemote(remote);
    });
  }

  @visibleForTesting
  Future<void> enqueueRemoteDecodeForTesting(
    int generation,
    Future<NoteOrderSnapshot?> Function() decode,
  ) {
    return _remoteEvents.run(generation, () async {
      final remote = await decode();
      if (remote == null) return;
      await _mutations.run(
        remote.context.key,
        () => _applyOrRebaseRemote(remote),
      );
    });
  }

  Future<void> _applyOrRebaseRemote(
    NoteOrderSnapshot remote, {
    _NoteSortCloudRun? run,
  }) async {
    if (run != null && !_isCurrentCloudRun(run)) return;
    final database = run?.session.database;
    final local = snapshots.value[remote.context.key];
    if (local?.revision == remote.revision && local?.dirty == false) return;
    final operations = await _loadOperations(
      remote.context.key,
      database: database,
    );
    if (run != null && !_isCurrentCloudRun(run)) return;
    if (operations.isEmpty) {
      await _persistSnapshot(remote, database: database);
      if (run != null && !_isCurrentCloudRun(run)) return;
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
    await _persistSnapshot(rebased, database: database);
    if (run != null && !_isCurrentCloudRun(run)) return;
    _publishSnapshot(rebased);
    _scheduleCloudWrite(run);
  }

  void _handlePlanChange() {
    final run = _cloudRun;
    if (run == null) return;
    if (_canPushCloud) {
      _scheduleCloudWrite(run);
    } else {
      _cloudWriteTimer?.cancel();
      _cloudWriteTimer = null;
      run.uploadRetry.cancel();
    }
  }

  void _scheduleCloudWrite([_NoteSortCloudRun? requestedRun]) {
    final run = requestedRun ?? _cloudRun;
    _cloudWriteTimer?.cancel();
    if (run == null ||
        !_isCurrentCloudRun(run) ||
        !run.bootstrapReady ||
        !_canPushCloud) {
      return;
    }
    _cloudWriteTimer = Timer(_cloudDebounce, () {
      if (!_isCurrentCloudRun(run)) return;
      _launchUpload(run);
    });
  }

  void _launchUpload(_NoteSortCloudRun run) {
    if (!_isCurrentCloudRun(run)) return;
    final upload = _trackCloudTask(_uploadDirtyContexts(run));
    _activeUpload = upload;
    unawaited(
      upload.then<void>(
        (_) {
          if (identical(_activeUpload, upload)) _activeUpload = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_activeUpload, upload)) _activeUpload = null;
        },
      ),
    );
  }

  Future<void> _uploadDirtyContexts(_NoteSortCloudRun run) async {
    if (!_isCurrentCloudRun(run) || !_canPushCloud || !run.bootstrapReady) {
      return;
    }
    if (run.uploading) {
      run.uploadAgain = true;
      return;
    }
    run.uploading = true;
    var retryableFailure = false;
    var authorizationStop = false;
    try {
      for (final snapshot in snapshots.value.values.toList()) {
        if (!_isCurrentCloudRun(run)) return;
        if (!snapshot.dirty) continue;
        final outcome = await _uploadSnapshot(run, snapshot);
        switch (outcome) {
          case _NoteSortUploadOutcome.retryableFailure:
            retryableFailure = true;
          case _NoteSortUploadOutcome.authorizationStop:
            authorizationStop = true;
          case _NoteSortUploadOutcome.success:
          case _NoteSortUploadOutcome.conflictRebased:
          case _NoteSortUploadOutcome.supersededSnapshot:
          case _NoteSortUploadOutcome.staleSession:
            break;
        }
      }
    } catch (error, stackTrace) {
      if (_isCurrentCloudRun(run)) {
        retryableFailure = true;
        AppLogger.error(
          '[NOTE_SORT] Failed to scan dirty order contexts',
          error,
          stackTrace,
        );
      }
    } finally {
      run.uploading = false;
    }
    if (!_isCurrentCloudRun(run)) return;

    final uploadAgain = run.uploadAgain;
    run.uploadAgain = false;
    final hasDirty = snapshots.value.values.any((snapshot) => snapshot.dirty);
    if (authorizationStop) {
      run.uploadRetry.cancel();
    } else if (retryableFailure) {
      _scheduleUploadRetry(run);
    } else if (uploadAgain || hasDirty) {
      run.uploadRetry.succeeded();
      _scheduleCloudWrite(run);
    } else {
      run.uploadRetry.succeeded();
    }
  }

  void _scheduleUploadRetry(_NoteSortCloudRun run) {
    if (!_isCurrentCloudRun(run) || !_canPushCloud) return;
    run.uploadRetry.schedule(() {
      if (_isCurrentCloudRun(run) && _canPushCloud) {
        _launchUpload(run);
      }
    });
  }

  Future<_NoteSortUploadOutcome> _uploadSnapshot(
    _NoteSortCloudRun run,
    NoteOrderSnapshot local,
  ) async {
    if (!_isCurrentCloudRun(run)) {
      return _NoteSortUploadOutcome.staleSession;
    }
    final chunks = chunkNoteIds(local.orderedNoteIds);
    var chunksMayExist = false;
    var manifestCommitted = false;
    try {
      await _journalCloudRevision(
        run,
        contextKey: local.context.key,
        revision: local.revision,
        chunkCount: chunks.length,
      );
      if (!_isCurrentCloudRun(run)) {
        return _NoteSortUploadOutcome.staleSession;
      }
      chunksMayExist = true;
      await run.session.repository.writeChunks(local.revision, chunks);
      if (!_isCurrentCloudRun(run)) {
        await _cleanupCandidateWithoutLocalState(
          run,
          contextKey: local.context.key,
          revision: local.revision,
          chunkCount: chunks.length,
        );
        return _NoteSortUploadOutcome.staleSession;
      }

      final currentBeforeCommit = snapshots.value[local.context.key];
      if (currentBeforeCommit?.revision != local.revision) {
        await _cleanupCloudRevision(
          run,
          contextKey: local.context.key,
          revision: local.revision,
          chunkCount: chunks.length,
        );
        return _NoteSortUploadOutcome.supersededSnapshot;
      }

      final commit = await run.session.repository.commitManifest(
        contextKey: local.context.key,
        sortMode: local.mode.name,
        revision: local.revision,
        baseRevision: local.baseRevision,
        chunkCount: chunks.length,
        noteCount: local.orderedNoteIds.length,
      );
      if (commit.outcome == NoteSortCloudCommitOutcome.conflict) {
        if (!_isCurrentCloudRun(run)) {
          await _cleanupCandidateWithoutLocalState(
            run,
            contextKey: local.context.key,
            revision: local.revision,
            chunkCount: chunks.length,
          );
          return _NoteSortUploadOutcome.staleSession;
        }
        return await _recoverManifestConflict(
          run,
          local: local,
          chunkCount: chunks.length,
          remoteRevision: commit.previousRevision,
        );
      }
      manifestCommitted = true;
      if (!_isCurrentCloudRun(run)) {
        return _NoteSortUploadOutcome.staleSession;
      }
      await _clearCloudCleanup(run, local.revision);
      if (!_isCurrentCloudRun(run)) {
        return _NoteSortUploadOutcome.staleSession;
      }

      final currentLocal = snapshots.value[local.context.key];
      if (currentLocal?.revision == local.revision) {
        final clean = local.copyWith(
          baseRevision: local.revision,
          dirty: false,
          hydrated: true,
        );
        await run.session.database.transaction((txn) async {
          await _persistSnapshot(clean, txn: txn);
          await txn.delete(
            operationTableName,
            where: 'context_key = ?',
            whereArgs: [local.context.key],
          );
        });
        if (!_isCurrentCloudRun(run)) {
          return _NoteSortUploadOutcome.staleSession;
        }
        _publishSnapshot(clean);
      }
      _remoteContextKeys.add(local.context.key);
      _remoteChunkCounts[local.revision] = chunks.length;
      final previousRevision = commit.previousRevision;
      if (previousRevision != null && previousRevision != local.revision) {
        await _journalCloudRevision(
          run,
          contextKey: local.context.key,
          revision: previousRevision,
          chunkCount: commit.previousChunkCount,
        );
        if (_isCurrentCloudRun(run)) {
          _trackCloudTask(_drainCloudCleanup(run));
        }
      }
      return _NoteSortUploadOutcome.success;
    } catch (error, stackTrace) {
      if (!_isCurrentCloudRun(run)) {
        if (chunksMayExist && !manifestCommitted) {
          await _cleanupCandidateWithoutLocalState(
            run,
            contextKey: local.context.key,
            revision: local.revision,
            chunkCount: chunks.length,
          );
        }
        return _NoteSortUploadOutcome.staleSession;
      }

      AppLogger.error(
        '[NOTE_SORT] Failed to upload ${local.context.key}',
        error,
        stackTrace,
      );
      await _cleanupCloudRevision(
        run,
        contextKey: local.context.key,
        revision: local.revision,
        chunkCount: chunks.length,
      );
      if (!_isCurrentCloudRun(run)) {
        return _NoteSortUploadOutcome.staleSession;
      }
      return _uploadFailureOutcome(error);
    }
  }

  Future<_NoteSortUploadOutcome> _recoverManifestConflict(
    _NoteSortCloudRun run, {
    required NoteOrderSnapshot local,
    required int chunkCount,
    required String? remoteRevision,
  }) async {
    AppLogger.log(
      '[NOTE_SORT] Rebasing ${local.context.key} from '
      '${local.baseRevision ?? 'no base'} onto '
      '${remoteRevision ?? 'the latest remote revision'}',
    );
    await _cleanupCloudRevision(
      run,
      contextKey: local.context.key,
      revision: local.revision,
      chunkCount: chunkCount,
    );
    if (!_isCurrentCloudRun(run)) {
      return _NoteSortUploadOutcome.staleSession;
    }

    try {
      final remote = await _readRemoteSnapshot(run, local.context.key);
      if (!_isCurrentCloudRun(run)) {
        return _NoteSortUploadOutcome.staleSession;
      }
      if (remote == null) {
        return _NoteSortUploadOutcome.retryableFailure;
      }
      await _mutations.run(
        local.context.key,
        () => _applyOrRebaseRemote(remote, run: run),
      );
      return _isCurrentCloudRun(run)
          ? _NoteSortUploadOutcome.conflictRebased
          : _NoteSortUploadOutcome.staleSession;
    } catch (error, stackTrace) {
      if (!_isCurrentCloudRun(run)) {
        return _NoteSortUploadOutcome.staleSession;
      }
      AppLogger.error(
        '[NOTE_SORT] Failed to recover order conflict',
        error,
        stackTrace,
      );
      return _uploadFailureOutcome(error);
    }
  }

  _NoteSortUploadOutcome _uploadFailureOutcome(Object error) {
    if (_isAuthorizationError(error)) {
      return _NoteSortUploadOutcome.authorizationStop;
    }
    return _NoteSortUploadOutcome.retryableFailure;
  }

  bool _isAuthorizationError(Object error) =>
      error is FirebaseException &&
      (error.code == 'unauthenticated' || error.code == 'permission-denied');

  Future<NoteOrderSnapshot?> _readRemoteSnapshot(
    _NoteSortCloudRun run,
    String contextKey,
  ) async {
    if (!_isCurrentCloudRun(run)) return null;
    final data = await run.session.repository.readManifest(contextKey);
    if (!_isCurrentCloudRun(run)) return null;
    if (data == null) return null;
    return _decodeRemoteData(run, contextKey, data);
  }

  Future<void> _journalCloudRevision(
    _NoteSortCloudRun run, {
    required String contextKey,
    required String revision,
    required int chunkCount,
  }) async {
    if (!_isCurrentCloudRun(run)) return;
    await run.session.database.insert(cleanupTableName, {
      'revision': revision,
      'context_key': contextKey,
      'chunk_count': chunkCount,
      'retry_count': 0,
      'next_retry_at': null,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _clearCloudCleanup(
    _NoteSortCloudRun run,
    String revision,
  ) async {
    if (!_isCurrentCloudRun(run)) return;
    await run.session.database.delete(
      cleanupTableName,
      where: 'revision = ?',
      whereArgs: [revision],
    );
  }

  Future<void> _cleanupCloudRevision(
    _NoteSortCloudRun run, {
    required String contextKey,
    required String revision,
    required int chunkCount,
  }) async {
    if (!_isCurrentCloudRun(run)) return;
    try {
      final manifest = await run.session.repository.readManifest(contextKey);
      if (!_isCurrentCloudRun(run)) return;
      if (manifest?['revision'] != revision) {
        await run.session.repository.deleteRevision(revision, chunkCount);
      }
      if (!_isCurrentCloudRun(run)) return;
      await _clearCloudCleanup(run, revision);
    } catch (error, stackTrace) {
      if (_isCurrentCloudRun(run) && !_isAuthorizationError(error)) {
        await _recordCloudCleanupFailure(run, revision);
      }
      AppLogger.error(
        '[NOTE_SORT] Failed to remove unreferenced order chunks',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _cleanupCandidateWithoutLocalState(
    _NoteSortCloudRun run, {
    required String contextKey,
    required String revision,
    required int chunkCount,
  }) async {
    try {
      final manifest = await run.session.repository.readManifest(contextKey);
      if (manifest?['revision'] != revision) {
        await run.session.repository.deleteRevision(revision, chunkCount);
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        '[NOTE_SORT] Failed stale-session candidate cleanup',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _recordCloudCleanupFailure(
    _NoteSortCloudRun run,
    String revision,
  ) async {
    if (!_isCurrentCloudRun(run)) return;
    final rows = await run.session.database.query(
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
    await run.session.database.update(
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
    if (_isCurrentCloudRun(run)) {
      _scheduleCloudCleanup(run, Duration(seconds: seconds));
    }
  }

  Future<void> _drainCloudCleanup(_NoteSortCloudRun run) async {
    if (!_isCurrentCloudRun(run) || !_canReceiveCloud) {
      return;
    }
    if (run.cleanupRunning) {
      run.cleanupAgain = true;
      return;
    }
    run.cleanupRunning = true;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final rows = await run.session.database.query(
        cleanupTableName,
        where: 'next_retry_at IS NULL OR next_retry_at <= ?',
        whereArgs: [now],
        orderBy: 'created_at ASC',
      );
      for (final row in rows) {
        if (!_isCurrentCloudRun(run)) return;
        final contextKey = row['context_key'];
        final revision = row['revision'];
        final chunkCount = row['chunk_count'];
        if (contextKey is! String ||
            revision is! String ||
            chunkCount is! int ||
            chunkCount < 0 ||
            chunkCount > maxCloudChunks) {
          if (revision is String) {
            await _clearCloudCleanup(run, revision);
          }
          continue;
        }
        await _cleanupCloudRevision(
          run,
          contextKey: contextKey,
          revision: revision,
          chunkCount: chunkCount,
        );
      }
      if (_isCurrentCloudRun(run)) {
        await _scheduleNextCloudCleanup(run);
      }
    } finally {
      run.cleanupRunning = false;
      if (_isCurrentCloudRun(run) && run.cleanupAgain) {
        run.cleanupAgain = false;
        _trackCloudTask(_drainCloudCleanup(run));
      }
    }
  }

  Future<void> _scheduleNextCloudCleanup(_NoteSortCloudRun run) async {
    if (!_isCurrentCloudRun(run)) return;
    final rows = await run.session.database.query(
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
    _scheduleCloudCleanup(run, delay.isNegative ? Duration.zero : delay);
  }

  void _scheduleCloudCleanup(_NoteSortCloudRun run, Duration delay) {
    if (!_isCurrentCloudRun(run)) return;
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer(delay, () {
      if (_isCurrentCloudRun(run)) {
        _trackCloudTask(_drainCloudCleanup(run));
      }
    });
  }

  @visibleForTesting
  Future<void> drainCloudCleanupForTesting() {
    return _drainCloudCleanup(_cloudRunForTesting());
  }

  @visibleForTesting
  Future<void> uploadSnapshotForTesting(NoteOrderSnapshot snapshot) async {
    await _trackCloudTask(_uploadSnapshot(_cloudRunForTesting(), snapshot));
  }

  @visibleForTesting
  Future<void> uploadSnapshotWithRetryForTesting(
    NoteOrderSnapshot snapshot,
  ) async {
    final run = _cloudRunForTesting();
    await _persistSnapshot(snapshot, database: run.session.database);
    if (!_isCurrentCloudRun(run)) return;
    _publishSnapshot(snapshot);
    await _uploadDirtyContexts(run);
  }

  @visibleForTesting
  bool get canReceiveCloudForTesting => _canReceiveCloud;

  @visibleForTesting
  bool get hasActiveCloudRunForTesting => _cloudRun != null;

  @visibleForTesting
  int get cloudGenerationForTesting => _nextCloudGeneration;

  @visibleForTesting
  void activateCloudRunForTesting() {
    _cloudRunForTesting();
  }

  Future<void> _migrateLegacyCloudIfNeeded(_NoteSortCloudRun run) async {
    if (!_isCurrentCloudRun(run) || run.legacyMigrationAttempted) return;
    run.legacyMigrationAttempted = true;
    try {
      final manifest = await _legacyManifestRef(run.session).get();
      if (!_isCurrentCloudRun(run)) return;
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
        final chunk = await _legacyChunkRef(run.session, revision, index).get();
        if (!_isCurrentCloudRun(run)) return;
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
          : await run.session.database.rawQuery(
              'SELECT id, sync_id FROM note WHERE id IN ($placeholders)',
              localIds,
            );
      if (!_isCurrentCloudRun(run)) return;
      final byLocalId = <int, String>{
        for (final row in rows)
          if (row['id'] is int && row['sync_id'] is String)
            row['id'] as int: row['sync_id'] as String,
      };
      final stableOrder = [
        for (final id in localIds)
          if (byLocalId[id] != null) byLocalId[id]!,
      ];
      final noteRows = await run.session.database.query(Note.model);
      if (!_isCurrentCloudRun(run)) return;
      final notes = noteRows
          .map((row) => Note.fromJson(Map<String, dynamic>.from(row)))
          .where((note) => !note.archived && !note.trashed)
          .toList();
      final labelRows = await run.session.database.query(
        Label.model,
        columns: ['sync_id'],
        where: 'sync_id IS NOT NULL',
      );
      if (!_isCurrentCloudRun(run)) return;
      final colorRows = await run.session.database.rawQuery('''
        SELECT DISTINCT color
        FROM note
        WHERE trashed = 0 AND archived = 0
        ORDER BY color ASC
        ''');
      if (!_isCurrentCloudRun(run)) return;
      final contexts = <NoteOrderContext>[
        const NoteOrderContext.mainGrid(),
        const NoteOrderContext.mainList(),
        const NoteOrderContext.pinned(),
        NoteOrderContext.label('__unlabeled__'),
        for (final row in labelRows)
          if (row['sync_id'] is String)
            NoteOrderContext.label(row['sync_id']! as String),
        for (final row in colorRows)
          NoteOrderContext.color(
            (int.tryParse(row['color']?.toString() ?? '') ?? 0).toUnsigned(32),
          ),
      ];
      for (final context in contexts) {
        if (!_isCurrentCloudRun(run)) return;
        if (_remoteContextKeys.contains(context.key)) continue;
        if ((await _loadOperations(
          context.key,
          database: run.session.database,
        )).isNotEmpty) {
          continue;
        }
        if (!_isCurrentCloudRun(run)) return;
        final matchingIds = <String>{};
        for (final note in notes) {
          if (await _noteBelongsToContext(
            note,
            context,
            database: run.session.database,
          )) {
            if (!_isCurrentCloudRun(run)) return;
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
        await _persistSnapshot(migrated, database: run.session.database);
        if (!_isCurrentCloudRun(run)) return;
        _publishSnapshot(migrated);
      }
    } catch (error, stackTrace) {
      if (_isCurrentCloudRun(run)) {
        AppLogger.error(
          '[NOTE_SORT] Legacy cloud migration failed safely',
          error,
          stackTrace,
        );
      }
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

  Future<void> _stopCloudSync() async {
    final run = _cloudRun;
    _cloudRun = null;
    _nextCloudGeneration++;
    run?.uploadRetry.cancel();
    PlanService.instance.statusNotifier.removeListener(_handlePlanChange);
    _cloudWriteTimer?.cancel();
    _cloudWriteTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    final remoteListener = _remoteListener;
    _remoteListener = null;
    _remoteListenerRetry.cancel();
    _remoteHydration.reset();
    _activeUpload = null;
    _deferredRemote.clear();
    _remoteChunkCounts.clear();
    _remoteContextKeys.clear();

    if (remoteListener != null) {
      await remoteListener.cancel();
    }
  }

  Future<void> dispose() async {
    E2EEService.instance.status.removeListener(_handleE2EEStatusChange);
    E2EEService.instance.deviceManager.hasUMK.removeListener(
      _handleE2EEStatusChange,
    );
    Note.off('changed', _handleNoteEvent);
    _initialized = false;
    _lastKnownCryptoReady = false;
    await _stopCloudSync();
    final tasks = _cloudTasks.toList();
    if (tasks.isNotEmpty) {
      try {
        await Future.wait<void>(
          tasks.map(
            (task) =>
                task.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
          ),
        ).timeout(disposeTimeoutOverride ?? const Duration(seconds: 5));
      } catch (error) {
        AppLogger.error(
          '[NOTE_SORT] Pending cloud work did not finish before disposal',
          error,
        );
      }
    }
    _cloudTasks.clear();
    _activeDragContexts.clear();
    snapshots.value = const {};
  }
}

class _NoteSortCloudSession {
  const _NoteSortCloudSession({
    required this.generation,
    required this.userId,
    required this.database,
    required this.firestore,
    required this.repository,
  });

  final int generation;
  final String userId;
  final Database database;
  final FirebaseFirestore? firestore;
  final NoteSortCloudRepository repository;
}

class _NoteSortCloudRun {
  _NoteSortCloudRun({required this.session, required this.uploadRetry});

  final _NoteSortCloudSession session;
  final ExponentialBackoffRetryController uploadRetry;
  bool remoteInitialResolved = false;
  bool dataHydrated = false;
  bool bootstrapReady = false;
  bool legacyMigrationAttempted = false;
  bool uploading = false;
  bool uploadAgain = false;
  bool cleanupRunning = false;
  bool cleanupAgain = false;
}

enum _NoteSortUploadOutcome {
  success,
  conflictRebased,
  supersededSnapshot,
  retryableFailure,
  authorizationStop,
  staleSession,
}
