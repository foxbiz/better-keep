import 'dart:async';

import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/rich_checklist.dart';
import 'package:better_keep/pages/note_editor/note_editor_app_bar.dart';
import 'package:better_keep/pages/note_editor/note_editor_toolbar.dart';
import 'package:better_keep/services/checklist_delta_codec.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:uuid/uuid.dart';

class RichChecklistEditor extends StatefulWidget {
  const RichChecklistEditor({
    super.key,
    required this.note,
    required this.session,
  }) : collectionSession = null;

  const RichChecklistEditor.collection({
    super.key,
    required this.note,
    required this.collectionSession,
  }) : session = null;

  final Note note;
  final ChecklistBlockEditSession? session;
  final ChecklistCollectionEditSession? collectionSession;

  @override
  State<RichChecklistEditor> createState() => _RichChecklistEditorState();
}

class RichChecklistCollectionEditor extends StatelessWidget {
  const RichChecklistCollectionEditor({
    super.key,
    required this.note,
    required this.session,
  });

  final Note note;
  final ChecklistCollectionEditSession session;

  @override
  Widget build(BuildContext context) =>
      RichChecklistEditor.collection(note: note, collectionSession: session);
}

class _RichChecklistEditorState extends State<RichChecklistEditor>
    with WidgetsBindingObserver {
  static const _autosaveDelay = Duration(seconds: 1);
  static const _rowCommitDelay = Duration(milliseconds: 180);
  static const _minimumFirstLineExtent = 42.0;

  final ChecklistDeltaCodec _codec = ChecklistDeltaCodec();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _rowFocusNode = FocusNode(debugLabel: 'checklist-row');
  final GlobalKey<QuillEditorState> _rowQuillEditorKey =
      GlobalKey<QuillEditorState>();
  final GlobalKey<EditorState> _rowEditorKey = GlobalKey<EditorState>();
  String? _titleOverride;
  late final ChecklistCollectionHistoryController _history;
  late final RichChecklistCollection _entryCollection;
  late final List<Map<String, dynamic>> _entryBodyDelta;
  late List<_ChecklistListEntry> _renderEntries;
  late List<Map<String, dynamic>> _bodyDelta;
  late String _activeSectionId;
  final Map<String, bool> _completedExpandedBySection = {};

  late final QuillController _rowController;
  StreamSubscription<DocChange>? _rowChanges;
  ValueNotifier<TextRange>? _rowComposingRange;
  VoidCallback? _pendingCompositionMutation;
  Timer? _rowCommitTimer;
  Timer? _autosaveTimer;
  Future<void> _saveTail = Future<void>.value();
  String? _activeItemId;
  String? _draggedItemId;
  String? _dragActiveItemId;
  TextSelection? _dragSelection;
  bool _restoreRowFocusAfterDrag = false;
  bool _applyingRowDocument = false;
  bool _performingRowSplit = false;
  bool _rowHasUncommittedChanges = false;
  bool _rowWasInteractedWith = false;
  bool _dirty = false;
  bool _closing = false;
  bool _allowPop = false;
  bool _externalConflict = false;
  String? _lastPersistedContent;
  Note? _externalNote;
  bool _requiresFullRefresh = false;

  bool get _collectionMode => widget.collectionSession != null;
  bool get _readOnly => widget.note.readOnly || widget.note.trashed;
  String get _title =>
      _titleOverride ??
      widget.note.title ??
      widget.collectionSession?.title ??
      widget.session?.title ??
      '';
  set _title(String value) => _titleOverride = value;
  RichChecklistCollection get _collection => _history.current.collection;
  RichChecklistSection get _activeSection =>
      _collection.sectionById(_activeSectionId) ??
      _collection.sections.firstWhere((section) => section.isEligible);
  RichChecklistDocument get _document => _activeSection.document!;
  bool get _hasEditableSections =>
      _collection.sections.any((section) => section.isEligible);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final collectionSession = widget.collectionSession;
    final blockSession = widget.session;
    late final RichChecklistCollection initialCollection;
    late final String initialTitle;
    if (collectionSession != null) {
      _bodyDelta = collectionSession.bodyDelta;
      _entryBodyDelta = collectionSession.bodyDelta;
      initialCollection = collectionSession.collection;
      initialTitle = widget.note.title ?? collectionSession.title;
    } else {
      final block = blockSession!.block;
      _bodyDelta = blockSession.bodyDelta;
      _entryBodyDelta = blockSession.bodyDelta;
      initialCollection = RichChecklistCollection([
        RichChecklistSection(
          id: 'focused-checklist-section',
          ordinal: blockSession.blockOrdinal,
          startOffset: block.startOffset,
          endOffset: block.endOffset,
          sourceDelta: block.sourceDelta,
          sourceFingerprint: block.sourceFingerprint,
          block: block,
          document: block.document,
          checkedCount: block.document.items
              .where((item) => item.checked)
              .length,
          totalCount: block.document.items.length,
        ),
      ]);
      initialTitle = widget.note.title ?? blockSession.title;
    }
    _entryCollection = initialCollection;
    _title = initialTitle;
    final initialSection = initialCollection.sections.firstWhere(
      (section) => section.isEligible,
      orElse: () => initialCollection.sections.first,
    );
    _activeSectionId = initialSection.id;
    final initialDocument =
        initialSection.document ??
        RichChecklistDocument([
          RichChecklistItem(
            id: 'unsupported-placeholder',
            inlineDelta: const [],
            checked: false,
            indent: 0,
          ),
        ]);
    final firstActive = initialDocument.items
        .cast<RichChecklistItem?>()
        .firstWhere(
          (item) => item != null && !item.checked,
          orElse: () => initialDocument.items.first,
        )!;
    _history = ChecklistCollectionHistoryController(initialCollection)
      ..replaceWithoutHistory(
        initialCollection,
        selection: ChecklistCollectionHistorySelection(
          sectionId: initialSection.isEligible ? initialSection.id : null,
          itemId: firstActive.id,
          baseOffset: firstActive.textLength,
          extentOffset: firstActive.textLength,
        ),
      )
      ..addListener(_onHistoryChanged);
    _activeItemId = initialSection.isEligible ? firstActive.id : null;
    _rowController = QuillController(
      document: _rowDocumentFor(firstActive),
      selection: TextSelection.collapsed(offset: firstActive.textLength),
      readOnly: _readOnly || !initialSection.isEligible,
      onReplaceText: _onBeforeRowTextReplaced,
      onSelectionChanged: _onRowSelectionChanged,
    );
    _rowChanges = _rowController.changes.listen(_onRowChanged);
    _renderEntries = initialSection.isEligible
        ? _createVisibleEntries(initialSection.id, initialDocument)
        : const [];
    _lastPersistedContent = widget.note.content;
    widget.note.sub('changed', _onNoteChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bindCompositionListener();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rowCommitTimer?.cancel();
    _autosaveTimer?.cancel();
    _rowChanges?.cancel();
    _rowComposingRange?.removeListener(_onCompositionChanged);
    _rowController.dispose();
    _rowFocusNode.dispose();
    _history
      ..removeListener(_onHistoryChanged)
      ..dispose();
    _scrollController.dispose();
    widget.note.unsub('changed', _onNoteChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _rowCommitTimer?.cancel();
      _commitActiveRow();
      unawaited(_enqueueSave());
    }
  }

  void _onHistoryChanged() {
    _syncVisibleEntries();
    if (_applyingRowDocument) {
      return;
    }
    _dirty = true;
    _scheduleAutosave();
  }

  void _onNoteChanged(NoteEvent event) {
    if (!mounted) return;
    if (identical(event.note, widget.note)) return;
    final noteId = widget.note.id;
    if (noteId == null || event.note.id != noteId) return;
    final remoteSession = _collectionSessionFromNote(event.note);
    if (remoteSession == null) return;
    final remoteTitle = event.note.title ?? remoteSession.title;
    final remoteCollection = remoteSession.collection;
    final sameTopology = _sameSectionTopology(_collection, remoteCollection);
    final checklistContentUnchanged =
        sameTopology &&
        List.generate(
          _collection.sections.length,
          (index) =>
              _collection.sections[index].sourceFingerprint ==
              remoteCollection.sections[index].sourceFingerprint,
        ).every((matches) => matches);

    final titleChanged = _title != remoteTitle;
    _title = remoteTitle;
    widget.note.title = remoteTitle;

    if (checklistContentUnchanged) {
      _bodyDelta = remoteSession.bodyDelta;
      _lastPersistedContent = event.note.content;
      _requiresFullRefresh = true;
      widget.note
        ..title = remoteTitle
        ..content = event.note.content
        ..plainText = event.note.plainText
        ..updatedAt = event.note.updatedAt;
      if (!_dirty) {
        _applyingRowDocument = true;
        final reloaded = _collectionWithStableIds(
          remoteCollection,
          preserveLocalDocuments: false,
        );
        _history.replaceWithoutHistory(reloaded);
        _applyingRowDocument = false;
        _activateFirstAvailable(requestFocus: false);
      } else {
        _applyingRowDocument = true;
        _history.rebaseSources(
          _collectionWithStableIds(
            remoteCollection,
            preserveLocalDocuments: true,
          ),
        );
        _applyingRowDocument = false;
        _scheduleAutosave();
      }
      if (titleChanged && mounted) setState(() {});
      return;
    }

    if (_dirty) {
      setState(() {
        _externalNote = event.note;
        _externalConflict = true;
      });
      return;
    }
    _reloadFromNote(event.note);
  }

  void _reloadFromNote(Note source) {
    final session = _collectionSessionFromNote(source);
    if (session == null) return;
    _rowCommitTimer?.cancel();
    _autosaveTimer?.cancel();
    _applyingRowDocument = true;
    _bodyDelta = session.bodyDelta;
    _title = source.title ?? session.title;
    widget.note
      ..title = _title
      ..content = source.content
      ..plainText = source.plainText
      ..updatedAt = source.updatedAt;
    _history.replaceWithoutHistory(
      _collectionWithStableIds(
        session.collection,
        preserveLocalDocuments: false,
      ),
    );
    _applyingRowDocument = false;
    _lastPersistedContent = source.content;
    _dirty = false;
    _externalConflict = false;
    _externalNote = null;
    _requiresFullRefresh = true;
    _activateFirstAvailable(requestFocus: false);
  }

  void _keepLocalAfterConflict() {
    final external = _externalNote;
    if (external == null) return;
    final remoteSession = _collectionSessionFromNote(external);
    if (remoteSession == null ||
        !_sameSectionTopology(_collection, remoteSession.collection)) {
      snackbar(context.l10n.somethingWentWrongTryAgain, Colors.orange);
      return;
    }
    _bodyDelta = remoteSession.bodyDelta;
    _title = external.title ?? remoteSession.title;
    widget.note.title = _title;
    _applyingRowDocument = true;
    _history.rebaseSources(
      _collectionWithStableIds(
        remoteSession.collection,
        preserveLocalDocuments: true,
      ),
    );
    _applyingRowDocument = false;
    _lastPersistedContent = external.content;
    _requiresFullRefresh = true;
    setState(() {
      _externalConflict = false;
      _externalNote = null;
    });
    _dirty = true;
    _scheduleAutosave();
  }

  ChecklistCollectionEditSession? _collectionSessionFromNote(Note note) {
    final parsed = _codec.tryParseCombinedJson(note.content);
    if (parsed == null) return null;
    final full = _codec.createCollectionEditSession(
      title: note.title ?? parsed.title,
      document: documentFromJsonSafe(parsed.bodyDelta),
      selectionStart: 0,
      selectionEnd: 0,
    );
    if (full == null) return null;
    if (_collectionMode) return full;
    final ordinal = widget.session!.blockOrdinal;
    if (ordinal < 0 || ordinal >= full.collection.sections.length) return null;
    var section = full.collection.sections[ordinal];
    final currentFingerprint = _collection.sections.single.sourceFingerprint;
    if (section.sourceFingerprint != currentFingerprint) {
      final fingerprintMatches = full.collection.sections
          .where(
            (candidate) => candidate.sourceFingerprint == currentFingerprint,
          )
          .toList(growable: false);
      if (fingerprintMatches.length == 1) section = fingerprintMatches.single;
    }
    if (!section.isEligible) return null;
    return ChecklistCollectionEditSession(
      title: full.title,
      bodyDelta: full.bodyDelta,
      collection: RichChecklistCollection([
        RichChecklistSection(
          id: 'focused-checklist-section',
          ordinal: section.ordinal,
          startOffset: section.startOffset,
          endOffset: section.endOffset,
          sourceDelta: section.sourceDelta,
          sourceFingerprint: section.sourceFingerprint,
          contextLabel: section.contextLabel,
          block: section.block,
          document: section.document,
          checkedCount: section.checkedCount,
          totalCount: section.totalCount,
        ),
      ]),
      selectionStart: 0,
      selectionEnd: 0,
    );
  }

  bool _sameSectionTopology(
    RichChecklistCollection local,
    RichChecklistCollection remote,
  ) {
    if (local.sections.length != remote.sections.length) return false;
    for (var index = 0; index < local.sections.length; index++) {
      if (local.sections[index].isEligible !=
          remote.sections[index].isEligible) {
        return false;
      }
    }
    return true;
  }

  RichChecklistCollection _collectionWithStableIds(
    RichChecklistCollection remote, {
    required bool preserveLocalDocuments,
  }) {
    if (!_sameSectionTopology(_collection, remote)) return remote;
    final sections = <RichChecklistSection>[];
    for (var index = 0; index < remote.sections.length; index++) {
      final local = _collection.sections[index];
      final source = remote.sections[index];
      final document = preserveLocalDocuments && local.isEligible
          ? local.document
          : source.document;
      final block = source.block == null || document == null
          ? null
          : source.block!.copyWith(document: document);
      sections.add(
        RichChecklistSection(
          id: local.id,
          ordinal: source.ordinal,
          startOffset: source.startOffset,
          endOffset: source.endOffset,
          sourceDelta: source.sourceDelta,
          sourceFingerprint: source.sourceFingerprint,
          contextLabel: source.contextLabel,
          block: block,
          document: document,
          failureReason: source.failureReason,
          failureMessage: source.failureMessage,
          checkedCount: document == null
              ? source.checkedCount
              : document.items.where((item) => item.checked).length,
          totalCount: document?.items.length ?? source.totalCount,
        ),
      );
    }
    return RichChecklistCollection(sections);
  }

  void _activateFirstAvailable({required bool requestFocus}) {
    final section = _collection.sections
        .cast<RichChecklistSection?>()
        .firstWhere(
          (candidate) => candidate?.isEligible ?? false,
          orElse: () => null,
        );
    if (section == null) {
      _activeItemId = null;
      if (mounted) setState(() {});
      return;
    }
    _activeSectionId = section.id;
    _activeItemId = null;
    _activateItem(section.document!.items.first.id, requestFocus: requestFocus);
  }

  void _scheduleAutosave() {
    if (_closing || _externalConflict || _readOnly) return;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(_autosaveDelay, () => unawaited(_enqueueSave()));
  }

  Future<void> _enqueueSave() {
    if (_readOnly || _externalConflict) return Future<void>.value();
    _commitActiveRow();
    final snapshot = _buildWorkspaceSnapshot();
    if (snapshot.content == _lastPersistedContent &&
        snapshot.title == (widget.note.title ?? '')) {
      _dirty = false;
      return Future<void>.value();
    }
    final save = _saveTail.then((_) async {
      try {
        final saved = await widget.note.saveEditorSnapshot(
          title: snapshot.title,
          content: snapshot.content,
          plainText: snapshot.plainText,
        );
        if (saved < 0) throw StateError('Checklist save returned $saved');
        _bodyDelta = snapshot.bodyDelta;
        _history.rebaseSources(snapshot.collection);
        _lastPersistedContent = snapshot.content;
        _dirty = false;
      } catch (error, stackTrace) {
        AppLogger.error('Failed to save checklist editor', error, stackTrace);
        if (mounted) snackbar(context.l10n.errorSavingNote, Colors.red);
        rethrow;
      }
    });
    _saveTail = save.then<void>((_) {}, onError: (_, _) {});
    return save;
  }

  _ChecklistWorkspaceSnapshot _buildWorkspaceSnapshot() {
    final title = _title;
    final currentSplice = _codec.replaceCollectionDocuments(
      bodyDelta: _bodyDelta,
      collection: _collection,
    );
    final entryCollection = _entryCollectionWithCurrentDocuments();
    final entrySplice = _codec.replaceCollectionDocuments(
      bodyDelta: _entryBodyDelta,
      collection: entryCollection,
    );
    final content = _codec.encodeCombinedBodyJson(
      title: title,
      bodyDelta: currentSplice.bodyDelta,
    );
    final selection = _globalActiveSelection(currentSplice.collection);
    return _ChecklistWorkspaceSnapshot(
      title: title,
      content: content,
      plainText: _codec.combinedBodyPlainText(
        title: title,
        bodyDelta: currentSplice.bodyDelta,
      ),
      bodyDelta: currentSplice.bodyDelta,
      collection: currentSplice.collection,
      entryReplacements: entrySplice.replacements,
      selectionStart: selection.baseOffset,
      selectionEnd: selection.extentOffset,
    );
  }

  RichChecklistCollection _entryCollectionWithCurrentDocuments() {
    final sections = <RichChecklistSection>[];
    for (final entry in _entryCollection.sections) {
      final current = _collection.sectionById(entry.id);
      if (!entry.isEligible || current?.document == null) {
        sections.add(entry);
      } else {
        sections.add(entry.withDocument(current!.document!));
      }
    }
    return RichChecklistCollection(sections);
  }

  TextSelection _globalActiveSelection(RichChecklistCollection collection) {
    if (!_rowWasInteractedWith) return _initialGlobalSelection();
    final section = collection.sectionById(_activeSectionId);
    final itemId = _activeItemId;
    if (section?.document != null && itemId != null) {
      final itemIndex = section!.document!.indexOfId(itemId);
      if (itemIndex >= 0) {
        var itemStart = section.startOffset;
        for (var index = 0; index < itemIndex; index++) {
          itemStart += section.document!.items[index].textLength + 1;
        }
        final local = _clampSelection(
          _rowController.selection,
          section.document!.items[itemIndex].textLength,
        );
        return TextSelection(
          baseOffset: itemStart + local.baseOffset,
          extentOffset: itemStart + local.extentOffset,
          affinity: local.affinity,
          isDirectional: local.isDirectional,
        );
      }
    }
    return _initialGlobalSelection();
  }

  TextSelection _initialGlobalSelection() {
    final initialStart = _collectionMode
        ? widget.collectionSession!.selectionStart
        : widget.session!.selectionStart;
    final initialEnd = _collectionMode
        ? widget.collectionSession!.selectionEnd
        : widget.session!.selectionEnd;
    final maxOffset = documentFromJsonSafe(_bodyDelta).length - 1;
    return TextSelection(
      baseOffset: initialStart.clamp(0, maxOffset),
      extentOffset: initialEnd.clamp(0, maxOffset),
    );
  }

  Object _navigationResult(_ChecklistWorkspaceSnapshot snapshot) {
    if (_collectionMode) {
      return RichChecklistCollectionEditorResult(
        title: snapshot.title,
        content: snapshot.content,
        plainText: snapshot.plainText,
        bodyDelta: snapshot.bodyDelta,
        replacements: snapshot.entryReplacements,
        selectionStart: snapshot.selectionStart,
        selectionEnd: snapshot.selectionEnd,
        requiresFullRefresh: _requiresFullRefresh,
      );
    }
    final replacement = snapshot.entryReplacements.single;
    return RichChecklistEditorResult(
      title: snapshot.title,
      content: snapshot.content,
      plainText: snapshot.plainText,
      document: _collection.sections.single.document!,
      bodyDelta: snapshot.bodyDelta,
      replacementDelta: replacement.replacementDelta,
      replacementStart: replacement.startOffset,
      replacementLength: replacement.sourceLength,
      sourceFingerprint: replacement.sourceFingerprint,
      selectionStart: snapshot.selectionStart,
      selectionEnd: snapshot.selectionEnd,
      requiresFullRefresh: _requiresFullRefresh,
    );
  }

  Future<void> _close() async {
    if (_closing) return;
    _rowCommitTimer?.cancel();
    _autosaveTimer?.cancel();
    _commitActiveRow();
    setState(() => _closing = true);
    try {
      await _enqueueSave();
      if (!mounted) return;
      final result = _navigationResult(_buildWorkspaceSnapshot());
      setState(() => _allowPop = true);
      Navigator.of(context).pop(result);
    } catch (_) {
      if (mounted) setState(() => _closing = false);
    }
  }

  void _activateItem(
    String id, {
    bool requestFocus = true,
    TextSelection? selection,
  }) {
    if (_hasActiveComposition) {
      _pendingCompositionMutation = () =>
          _activateItem(id, requestFocus: requestFocus, selection: selection);
      return;
    }
    if (requestFocus) _rowWasInteractedWith = true;
    final targetSection = _sectionContainingItem(id);
    if (targetSection == null) return;
    if (_activeItemId == id) {
      if (selection != null) {
        _rowController.updateSelection(
          _clampSelection(selection, _rowController.document.length - 1),
          ChangeSource.local,
        );
      }
      if (requestFocus && !_readOnly) {
        _requestRowKeyboard(id);
      }
      return;
    }
    _rowCommitTimer?.cancel();
    _commitActiveRow();
    if (_hasActiveComposition) {
      _pendingCompositionMutation = () =>
          _activateItem(id, requestFocus: requestFocus, selection: selection);
      return;
    }
    _activeSectionId = targetSection.id;
    final item = _document.itemById(id);
    if (item == null) return;

    _rowChanges?.cancel();
    final retiredDocument = _rowController.document;
    final rowDocument = _rowDocumentFor(item);
    final nextSelection = _clampSelection(
      selection ?? TextSelection.collapsed(offset: item.textLength),
      item.textLength,
    );
    _applyingRowDocument = true;
    _activeItemId = id;
    _rowController.document = rowDocument;
    _rowController.updateSelection(nextSelection, ChangeSource.local);
    _rowChanges = _rowController.changes.listen(_onRowChanged);
    _rowHasUncommittedChanges = false;
    _history.commit(
      _collection,
      selection: ChecklistCollectionHistorySelection(
        sectionId: _activeSectionId,
        itemId: id,
        baseOffset: nextSelection.baseOffset,
        extentOffset: nextSelection.extentOffset,
      ),
    );
    _applyingRowDocument = false;
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      retiredDocument.close();
      if (mounted) _bindCompositionListener();
    });
    if (requestFocus && !_readOnly) {
      _requestRowKeyboard(id);
    }
  }

  RichChecklistSection? _sectionContainingItem(String itemId) {
    for (final section in _collection.sections) {
      if (section.document?.itemById(itemId) != null) return section;
    }
    return null;
  }

  Document _rowDocumentFor(RichChecklistItem item) => documentFromJsonSafe([
    ...item.inlineDelta.map(
      (operation) => Map<String, dynamic>.from(operation),
    ),
    {
      'insert': '\n',
      if (item.lineAttributes.isNotEmpty) 'attributes': item.lineAttributes,
    },
  ]);

  TextSelection _clampSelection(TextSelection selection, int textLength) {
    final baseOffset = selection.baseOffset.clamp(0, textLength);
    final extentOffset = selection.extentOffset.clamp(0, textLength);
    return TextSelection(
      baseOffset: baseOffset,
      extentOffset: extentOffset,
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  void _requestRowKeyboard(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _readOnly || _activeItemId != id) {
        return;
      }
      if (!_rowFocusNode.hasFocus) {
        _rowFocusNode.requestFocus();
      }
      _rowEditorKey.currentState?.requestKeyboard();
      _bindCompositionListener();
    });
  }

  bool get _hasActiveComposition {
    final range = _rowComposingRange?.value;
    return range != null && range.isValid && !range.isCollapsed;
  }

  void _bindCompositionListener() {
    final state = _rowEditorKey.currentState;
    if (state is! QuillRawEditorState) return;
    final next = state.composingRange;
    if (identical(_rowComposingRange, next)) return;
    _rowComposingRange?.removeListener(_onCompositionChanged);
    _rowComposingRange = next..addListener(_onCompositionChanged);
  }

  void _onCompositionChanged() {
    if (_hasActiveComposition) return;
    final mutation = _pendingCompositionMutation;
    if (mutation == null) return;
    _pendingCompositionMutation = null;
    mutation();
  }

  void _onRowSelectionChanged(TextSelection selection) {
    if (_applyingRowDocument || _rowHasUncommittedChanges) return;
    final id = _activeItemId;
    if (id == null) return;
    final clamped = _clampSelection(
      selection,
      _document.itemById(id)?.textLength ?? 0,
    );
    _history.commit(
      _collection,
      selection: ChecklistCollectionHistorySelection(
        sectionId: _activeSectionId,
        itemId: id,
        baseOffset: clamped.baseOffset,
        extentOffset: clamped.extentOffset,
      ),
    );
  }

  bool _onBeforeRowTextReplaced(int index, int length, Object? data) {
    final changesText = length > 0 || data is! String || data.isNotEmpty;
    if (!_applyingRowDocument && changesText) {
      _rowHasUncommittedChanges = true;
    }
    return true;
  }

  void _onRowChanged(DocChange change) {
    if (_applyingRowDocument || _readOnly) return;
    _rowHasUncommittedChanges = true;
    _rowCommitTimer?.cancel();
    final text = _rowController.document.toPlainText();
    if (text.indexOf('\n') < text.length - 1) {
      _splitActiveItem();
      return;
    }
    _rowCommitTimer = Timer(_rowCommitDelay, _commitActiveRow);
  }

  bool _commitActiveRow() {
    if (_applyingRowDocument) return false;
    if (_hasActiveComposition) {
      _pendingCompositionMutation ??= _commitActiveRow;
      return false;
    }
    final id = _activeItemId;
    final controller = _rowController;
    if (id == null) return false;
    final original = _document.itemById(id);
    if (original == null) return false;

    final selection = controller.selection;
    final decoded = _codec.tryDecodeEditedRow(
      original: original,
      document: controller.document,
    );
    if (!decoded.isEligible) {
      _restoreActiveRowAfterInvalidEdit(decoded.failureReason);
      return false;
    }

    final replacements = decoded.document!.items;
    final updated = replacements.length == 1
        ? _document.replaceItem(replacements.single)
        : _document.replaceItemWith(id: id, replacements: replacements);
    final nextFocus = replacements.length == 1 ? id : replacements.last.id;
    _history.commit(
      _collection.replaceDocument(_activeSectionId, updated),
      selection: ChecklistCollectionHistorySelection(
        sectionId: _activeSectionId,
        itemId: nextFocus,
        baseOffset: replacements.length == 1 ? selection.baseOffset : 0,
        extentOffset: replacements.length == 1 ? selection.extentOffset : 0,
      ),
      coalesceKey: replacements.length == 1
          ? 'typing:$_activeSectionId:$id'
          : null,
    );
    _rowHasUncommittedChanges = false;
    if (replacements.length > 1) {
      _activeItemId = null;
      _activateItem(
        nextFocus,
        selection: const TextSelection.collapsed(offset: 0),
      );
      return true;
    }
    return false;
  }

  void _restoreActiveRowAfterInvalidEdit(
    ChecklistDeltaFailureReason? failureReason,
  ) {
    final id = _activeItemId;
    if (id == null) return;
    final isEmbed = failureReason == ChecklistDeltaFailureReason.embed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      snackbar(
        isEmbed
            ? context.l10n.checklistEmbedUnsupported
            : context.l10n.somethingWentWrongTryAgain,
        Colors.orange,
      );
      _activeItemId = null;
      _activateItem(id, requestFocus: true);
    });
  }

  void _splitActiveItem() {
    if (_readOnly || _performingRowSplit) return;
    if (_hasActiveComposition) {
      _pendingCompositionMutation = _splitActiveItem;
      return;
    }
    _performingRowSplit = true;
    try {
      _splitActiveItemNow();
    } finally {
      _performingRowSplit = false;
    }
  }

  void _splitActiveItemNow() {
    _rowCommitTimer?.cancel();
    if (_commitActiveRow()) return;
    final id = _activeItemId;
    final controller = _rowController;
    if (id == null) return;
    final item = _document.itemById(id);
    if (item == null) return;
    if (item.isEmpty && item.indent > 0) {
      _commitDocument(_document.outdentSubtree(id), focusId: id);
      return;
    }
    if (item.isEmpty) return;

    final selection = controller.selection;
    if (!selection.isCollapsed) {
      controller.replaceText(
        selection.start,
        selection.end - selection.start,
        '',
        null,
      );
      _commitActiveRow();
    }
    final updated = _document.splitItem(
      id: id,
      offset: controller.selection.baseOffset,
      newId: _newId,
    );
    final originalIndex = updated.indexOfId(id);
    final originalEnd = updated.subtreeEnd(originalIndex);
    final nextId = updated.items[originalEnd].id;
    _commitDocument(updated, focusId: nextId, selectionOffset: 0);
  }

  KeyEventResult _handleRowKey(KeyEvent event) {
    if (event is! KeyDownEvent || _readOnly) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _splitActiveItem();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      final id = _activeItemId;
      if (id == null) return KeyEventResult.ignored;
      if (HardwareKeyboard.instance.isShiftPressed) {
        _commitDocument(_document.outdentSubtree(id), focusId: id);
      } else {
        _commitDocument(_document.indentSubtree(id), focusId: id);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      final controller = _rowController;
      final id = _activeItemId;
      if (id != null &&
          controller.selection.isCollapsed &&
          controller.selection.baseOffset == 0) {
        _rowCommitTimer?.cancel();
        _commitActiveRow();
        final item = _document.itemById(id);
        if (item?.isEmpty ?? false) {
          _deleteItem(id, focusPreviousAtEnd: true);
          return KeyEventResult.handled;
        }
        final previous = _document.previousSiblingOf(id);
        if (item != null && previous != null) {
          final selectionOffset = previous.textLength;
          _commitDocument(
            _document.mergeWithPrevious(id),
            focusId: previous.id,
            selectionOffset: selectionOffset,
          );
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  void _commitDocument(
    RichChecklistDocument document, {
    String? focusId,
    int? selectionOffset,
    TextSelection? selection,
    bool requestFocus = true,
  }) {
    if (_readOnly) return;
    assert(selectionOffset == null || selection == null);
    final targetId = focusId ?? _activeItemId;
    final nextSelection =
        selection ??
        (selectionOffset != null
            ? TextSelection.collapsed(offset: selectionOffset)
            : targetId == _activeItemId
            ? _rowController.selection
            : const TextSelection.collapsed(offset: 0));
    _history.commit(
      _collection.replaceDocument(_activeSectionId, document),
      selection: ChecklistCollectionHistorySelection(
        sectionId: _activeSectionId,
        itemId: targetId,
        baseOffset: nextSelection.baseOffset,
        extentOffset: nextSelection.extentOffset,
      ),
    );
    if (targetId != null && document.itemById(targetId) != null) {
      _activeItemId = null;
      _activateItem(
        targetId,
        selection: nextSelection,
        requestFocus: requestFocus,
      );
    }
  }

  bool _prepareSectionForItem(String id) {
    final section = _sectionContainingItem(id);
    if (section == null) return false;
    if (section.id == _activeSectionId) return true;
    _rowCommitTimer?.cancel();
    _commitActiveRow();
    _activeSectionId = section.id;
    return true;
  }

  void _toggleItem(String id, bool checked) {
    _rowCommitTimer?.cancel();
    _commitActiveRow();
    if (!_prepareSectionForItem(id)) return;
    final updated = _document.toggle(id, checked);
    _commitDocument(updated, focusId: id);
  }

  void _indentItem(String id) {
    if (!_prepareSectionForItem(id)) return;
    _commitDocument(_document.indentSubtree(id), focusId: id);
  }

  void _outdentItem(String id) {
    if (!_prepareSectionForItem(id)) return;
    _commitDocument(_document.outdentSubtree(id), focusId: id);
  }

  void _deleteItem(String id, {bool focusPreviousAtEnd = false}) {
    if (_readOnly) return;
    if (!_prepareSectionForItem(id)) return;
    if (_document.items.length == 1 && _document.items.single.id == id) return;
    _rowCommitTimer?.cancel();
    _commitActiveRow();
    final index = _document.indexOfId(id);
    final fallbackIndex = index <= 0 ? 0 : index - 1;
    final updated = _document.deleteSubtree(id, newId: _newId);
    final focusItem =
        updated.items[fallbackIndex.clamp(0, updated.items.length - 1)];
    _commitDocument(
      updated,
      focusId: focusItem.id,
      selectionOffset: focusPreviousAtEnd && index > 0
          ? focusItem.textLength
          : null,
    );
  }

  void _clearCompleted([String? sectionId]) {
    if (_readOnly) return;
    _rowCommitTimer?.cancel();
    _commitActiveRow();
    if (sectionId != null) _activeSectionId = sectionId;
    final updated = _document.clearCompleted(newId: _newId);
    _commitDocument(updated, focusId: updated.items.first.id);
  }

  void _reorderVisibleEntry(
    String sectionId,
    List<_ChecklistListEntry> entries,
    int oldIndex,
    int newIndex,
  ) {
    if (_readOnly || oldIndex < 0 || oldIndex >= entries.length) {
      return;
    }
    final draggedEntry = entries[oldIndex];
    final dragged = draggedEntry.item;
    if (dragged == null) return;

    _rowCommitTimer?.cancel();
    _commitActiveRow();
    final preservedSectionId = _activeSectionId;
    _activeSectionId = sectionId;
    final preservedFocusId = _dragActiveItemId ?? _activeItemId;
    final preservedSelection = _dragSelection ?? _rowController.selection;
    final draggedIndex = _document.indexOfId(dragged.id);
    if (draggedIndex < 0) return;
    final subtreeIds = _document.items
        .sublist(draggedIndex, _document.subtreeEnd(draggedIndex))
        .map((item) => item.id)
        .toSet();

    final entriesAfterDragged = [...entries]..removeAt(oldIndex);
    var insertionIndex = newIndex;
    insertionIndex = insertionIndex.clamp(0, entriesAfterDragged.length);
    final descendantsBeforeInsertion = entriesAfterDragged
        .take(insertionIndex)
        .where((entry) => subtreeIds.contains(entry.item?.id))
        .length;
    insertionIndex -= descendantsBeforeInsertion;

    final remaining = entriesAfterDragged
        .where((entry) => !subtreeIds.contains(entry.item?.id))
        .toList(growable: false);
    if (remaining.isEmpty) return;

    RichChecklistItem? target;
    var placeAfter = false;
    if (insertionIndex >= remaining.length) {
      for (final entry in remaining.reversed) {
        if (entry.item != null) {
          target = entry.item;
          break;
        }
      }
      placeAfter = true;
    } else {
      target = remaining[insertionIndex].item;
    }
    if (target == null ||
        target.indent != dragged.indent ||
        _parentIdFor(target.id) != _parentIdFor(dragged.id)) {
      setState(() {});
      return;
    }

    final updated = placeAfter
        ? _document.moveSubtreeAfter(id: dragged.id, targetId: target.id)
        : _document.moveSubtreeBefore(id: dragged.id, targetId: target.id);
    if (preservedFocusId != null &&
        updated.itemById(preservedFocusId) != null) {
      _commitDocument(
        updated,
        focusId: preservedFocusId,
        selection: preservedSelection,
        requestFocus: _restoreRowFocusAfterDrag,
      );
    } else {
      _history.commit(
        _collection.replaceDocument(sectionId, updated),
        selection: _history.current.selection,
      );
      _activeSectionId = preservedSectionId;
    }
  }

  String? _parentIdFor(String id) {
    final index = _document.indexOfId(id);
    if (index < 0) return null;
    final indent = _document.items[index].indent;
    if (indent == 0) return null;
    for (var candidate = index - 1; candidate >= 0; candidate--) {
      final item = _document.items[candidate];
      if (item.indent == indent - 1) return item.id;
      if (item.indent < indent - 1) return null;
    }
    return null;
  }

  void _undo() {
    _rowCommitTimer?.cancel();
    _commitActiveRow();
    final entry = _history.undo();
    if (entry != null) _restoreHistorySelection(entry);
  }

  void _redo() {
    _rowCommitTimer?.cancel();
    _commitActiveRow();
    final entry = _history.redo();
    if (entry != null) _restoreHistorySelection(entry);
  }

  void _restoreHistorySelection(ChecklistCollectionHistoryEntry entry) {
    final selection = entry.selection;
    final id = selection?.itemId;
    final sectionId = selection?.sectionId;
    final section = sectionId == null
        ? null
        : entry.collection.sectionById(sectionId);
    if (id != null && section?.document?.itemById(id) != null) {
      _activeSectionId = sectionId!;
      _activeItemId = null;
      _activateItem(
        id,
        selection: TextSelection(
          baseOffset: selection!.baseOffset,
          extentOffset: selection.extentOffset,
        ),
      );
    } else {
      _activateFirstAvailable(requestFocus: false);
    }
  }

  String _newId() => const Uuid().v4();

  int _firstCompletedRootIndex(RichChecklistDocument document) {
    for (var index = 0; index < document.items.length; index++) {
      final item = document.items[index];
      if (item.indent == 0 && item.checked) return index;
    }
    return -1;
  }

  List<_ChecklistListEntry> _createVisibleEntries(
    String sectionId,
    RichChecklistDocument document,
  ) {
    final entries = <_ChecklistListEntry>[];
    final completedIndex = _firstCompletedRootIndex(document);
    final completedExpanded = _completedExpandedBySection[sectionId] ?? true;
    for (var index = 0; index < document.items.length; index++) {
      if (index == completedIndex) {
        entries.add(const _ChecklistListEntry.completedHeader());
        if (!completedExpanded) break;
      }
      entries.add(_ChecklistListEntry.item(document.items[index]));
    }
    return entries;
  }

  void _syncVisibleEntries() {
    if (!mounted) return;
    final section = _collection.sectionById(_activeSectionId);
    setState(() {
      _renderEntries = section?.document == null
          ? const []
          : _createVisibleEntries(section!.id, section.document!);
    });
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = widget.note.color == Colors.transparent
        ? Theme.of(context).colorScheme.surface
        : widget.note.color;
    final foregroundColor = isDark(backgroundColor)
        ? Colors.white
        : Colors.black;
    final placeholderColor = foregroundColor.withValues(alpha: 0.4);
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_close());
      },
      child: AbsorbPointer(
        absorbing: _closing,
        child: Scaffold(
          backgroundColor: backgroundColor,
          appBar: NoteEditorAppBar(
            backgroundColor: backgroundColor,
            foregroundColor: foregroundColor,
            leading: BackButton(
              color: foregroundColor,
              onPressed: () => unawaited(_close()),
            ),
            title: Text(
              _title,
              key: const ValueKey('rich_checklist_note_title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: NoteCheckboxProgressTitle(
                  checked: _collectionMode
                      ? _collection.checkedCount
                      : _activeSection.checkedCount,
                  total: _collectionMode
                      ? _collection.totalCount
                      : _activeSection.totalCount,
                  foregroundColor: foregroundColor,
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              if (_externalConflict)
                MaterialBanner(
                  content: Text(context.l10n.checklistChangedElsewhere),
                  actions: [
                    TextButton(
                      onPressed: _externalNote == null
                          ? null
                          : () => _reloadFromNote(_externalNote!),
                      child: Text(context.l10n.reloadChecklist),
                    ),
                    TextButton(
                      onPressed: _keepLocalAfterConflict,
                      child: Text(context.l10n.keepChecklistEdits),
                    ),
                  ],
                ),
              Expanded(
                child: _collectionMode
                    ? _buildCollectionList(
                        backgroundColor,
                        foregroundColor,
                        placeholderColor,
                      )
                    : _buildSingleSectionList(
                        backgroundColor,
                        foregroundColor,
                        placeholderColor,
                      ),
              ),
            ],
          ),
          bottomNavigationBar: _readOnly || !_hasEditableSections
              ? null
              : AnimatedPadding(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: SafeArea(
                    top: false,
                    child: _buildFormattingToolbar(backgroundColor),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildSingleSectionList(
    Color backgroundColor,
    Color foregroundColor,
    Color placeholderColor,
  ) {
    final section = _activeSection;
    final entries = _renderEntries;
    return ReorderableListView.builder(
      scrollController: _scrollController,
      key: const ValueKey('rich_checklist_scroll_view'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      buildDefaultDragHandles: false,
      itemCount: entries.length,
      onReorderItem: (oldIndex, newIndex) =>
          _reorderVisibleEntry(section.id, entries, oldIndex, newIndex),
      onReorderStart: (index) => _onReorderStart(entries, index),
      onReorderEnd: _onReorderEnd,
      proxyDecorator: _buildDragProxy,
      itemBuilder: (context, index) => _buildListEntry(
        section,
        entries,
        index,
        backgroundColor,
        foregroundColor,
        placeholderColor,
      ),
    );
  }

  Widget _buildCollectionList(
    Color backgroundColor,
    Color foregroundColor,
    Color placeholderColor,
  ) {
    final slivers = <Widget>[];
    for (final section in _collection.sections) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(section, foregroundColor),
        ),
      );
      if (!section.isEligible) {
        slivers.add(
          SliverToBoxAdapter(
            child: _buildUnsupportedSection(section, foregroundColor),
          ),
        );
        continue;
      }
      final entries = _createVisibleEntries(section.id, section.document!);
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverReorderableList(
            key: ValueKey('checklist-section-list-${section.id}'),
            itemCount: entries.length,
            onReorderItem: (oldIndex, newIndex) =>
                _reorderVisibleEntry(section.id, entries, oldIndex, newIndex),
            onReorderStart: (index) => _onReorderStart(entries, index),
            onReorderEnd: _onReorderEnd,
            proxyDecorator: _buildDragProxy,
            itemBuilder: (context, index) => _buildListEntry(
              section,
              entries,
              index,
              backgroundColor,
              foregroundColor,
              placeholderColor,
            ),
          ),
        ),
      );
    }
    slivers.add(const SliverPadding(padding: EdgeInsets.only(bottom: 16)));
    return CustomScrollView(
      key: const ValueKey('rich_checklist_collection_scroll_view'),
      controller: _scrollController,
      slivers: slivers,
    );
  }

  Widget _buildListEntry(
    RichChecklistSection section,
    List<_ChecklistListEntry> entries,
    int index,
    Color backgroundColor,
    Color foregroundColor,
    Color placeholderColor,
  ) {
    final entry = entries[index];
    return KeyedSubtree(
      key: ValueKey('checklist-entry-${section.id}-${entry.identity}'),
      child: entry.isCompletedHeader
          ? _buildCompletedHeader(
              section.id,
              foregroundColor,
              section.document!.items
                  .where((item) => item.indent == 0 && item.checked)
                  .length,
            )
          : _buildItemRow(
              entry.item!,
              backgroundColor,
              foregroundColor,
              placeholderColor,
              reorderIndex: index,
            ),
    );
  }

  Widget _buildSectionHeader(
    RichChecklistSection section,
    Color foregroundColor,
  ) {
    final label = section.contextLabel?.trim();
    return Padding(
      key: ValueKey('checklist-section-header-${section.id}'),
      padding: const EdgeInsetsDirectional.fromSTEB(20, 18, 20, 8),
      child: Row(
        children: [
          if (label != null && label.isNotEmpty) ...[
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foregroundColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
          ] else
            const Spacer(),
          Text(
            '${section.checkedCount}/${section.totalCount}',
            key: ValueKey('checklist-section-progress-${section.id}'),
            style: TextStyle(
              color: foregroundColor.withValues(alpha: 0.72),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupportedSection(
    RichChecklistSection section,
    Color foregroundColor,
  ) {
    final text = documentFromJsonSafe(section.sourceDelta).toPlainText().trim();
    return Container(
      key: ValueKey('unsupported-checklist-section-${section.id}'),
      margin: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: foregroundColor.withValues(alpha: 0.055),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            color: foregroundColor.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (text.isNotEmpty) ...[
                  Text(
                    text,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: foregroundColor),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  _unsupportedSectionMessage(section),
                  style: TextStyle(
                    color: foregroundColor.withValues(alpha: 0.72),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _unsupportedSectionMessage(RichChecklistSection section) =>
      switch (section.failureReason) {
        ChecklistDeltaFailureReason.embed ||
        ChecklistDeltaFailureReason.textBlockAttributes ||
        ChecklistDeltaFailureReason.incompatibleBlock =>
          context.l10n.focusedChecklistUnsupportedContent,
        _ => context.l10n.focusedChecklistInvalidContent,
      };

  void _onReorderStart(List<_ChecklistListEntry> entries, int index) {
    final entry = entries[index];
    _dragActiveItemId = _activeItemId;
    _dragSelection = _rowController.selection;
    _restoreRowFocusAfterDrag = _rowFocusNode.hasFocus;
    unawaited(HapticFeedback.selectionClick());
    setState(() => _draggedItemId = entry.item?.id);
  }

  void _onReorderEnd(int _) {
    final focusId = _dragActiveItemId;
    final restoreFocus = _restoreRowFocusAfterDrag;
    _dragActiveItemId = null;
    _dragSelection = null;
    _restoreRowFocusAfterDrag = false;
    if (!mounted) return;
    setState(() => _draggedItemId = null);
    if (restoreFocus && focusId != null) _requestRowKeyboard(focusId);
  }

  Widget _buildDragProxy(
    Widget child,
    int index,
    Animation<double> animation,
  ) => Material(
    type: MaterialType.transparency,
    elevation: 0,
    child: FadeTransition(
      opacity: Tween<double>(
        begin: 0.9,
        end: 1,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );

  Widget _buildCompletedHeader(
    String sectionId,
    Color foregroundColor,
    int count,
  ) {
    final completedExpanded = _completedExpandedBySection[sectionId] ?? true;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 18, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                _completedExpandedBySection[sectionId] = !completedExpanded;
                _syncVisibleEntries();
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    AnimatedRotation(
                      duration: const Duration(milliseconds: 180),
                      turns: completedExpanded ? 0.25 : 0,
                      child: Icon(Icons.chevron_right, color: foregroundColor),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${context.l10n.completedTasks} ($count)',
                      style: TextStyle(
                        color: foregroundColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: _readOnly ? null : () => _clearCompleted(sectionId),
            child: Text(context.l10n.clearCompletedTasks),
          ),
        ],
      ),
    );
  }

  ({double extent, double verticalInset}) _firstLineMetricsFor(
    RichChecklistItem item,
  ) {
    var largestFontSize = 16.0;
    for (final operation in item.delta.toList()) {
      final attributes = operation.attributes;
      final configuredSize = _parseNumber(attributes?['size']);
      if (configuredSize == null) continue;
      final script = attributes?['script'];
      final renderedSize = script == 'sub' || script == 'super'
          ? configuredSize * 0.75
          : configuredSize;
      if (renderedSize > largestFontSize) largestFontSize = renderedSize;
    }
    final lineHeight = _parseNumber(item.lineAttributes['line-height']) ?? 1.2;
    final renderedLineHeight = largestFontSize * lineHeight;
    final extent = (renderedLineHeight + 18).clamp(
      _minimumFirstLineExtent,
      double.infinity,
    );
    return (extent: extent, verticalInset: (extent - renderedLineHeight) / 2);
  }

  Widget _buildItemRow(
    RichChecklistItem item,
    Color backgroundColor,
    Color foregroundColor,
    Color placeholderColor, {
    required int reorderIndex,
  }) {
    final active = item.id == _activeItemId;
    final dragging = item.id == _draggedItemId;
    final firstLineMetrics = _firstLineMetricsFor(item);
    final firstLineExtent = firstLineMetrics.extent;
    final rowMargin = EdgeInsetsDirectional.only(
      start: item.indent * 22.0,
      bottom: 4,
    );
    final rowColor = foregroundColor.withValues(
      alpha: active && !dragging ? 0.1 : 0.045,
    );
    final row = AnimatedContainer(
      key: ValueKey('checklist-row-surface-${item.id}'),
      duration: const Duration(milliseconds: 180),
      margin: rowMargin,
      padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 2, 4),
      decoration: BoxDecoration(
        color: rowColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            key: ValueKey('checklist-leading-lane-${item.id}'),
            height: firstLineExtent,
            child: Center(
              child: _AnimatedChecklistBox(
                key: ValueKey('checklist-checkbox-${item.id}'),
                checked: item.checked,
                enabled: !_readOnly,
                color: foregroundColor,
                onChanged: (checked) => _toggleItem(item.id, checked),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ConstrainedBox(
              key: ValueKey('checklist-text-lane-${item.id}'),
              constraints: BoxConstraints(minHeight: firstLineExtent),
              child: active
                  ? Opacity(
                      opacity: item.checked ? 0.62 : 1,
                      child: _buildActiveRowEditor(
                        item,
                        backgroundColor,
                        foregroundColor,
                        placeholderColor,
                        verticalInset: firstLineMetrics.verticalInset,
                      ),
                    )
                  : InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _activateItem(item.id),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          vertical: firstLineMetrics.verticalInset,
                        ),
                        child: item.isEmpty
                            ? Text(
                                context.l10n.startWriting,
                                style: TextStyle(color: placeholderColor),
                              )
                            : _RichChecklistText(
                                item: item,
                                foregroundColor: foregroundColor,
                                completed: item.checked,
                              ),
                      ),
                    ),
            ),
          ),
          if (!_readOnly)
            SizedBox(
              height: firstLineExtent,
              child: Center(
                child: PopupMenuButton<String>(
                  tooltip: context.l10n.tasks,
                  onSelected: (action) {
                    switch (action) {
                      case 'indent':
                        _indentItem(item.id);
                      case 'outdent':
                        _outdentItem(item.id);
                      case 'delete':
                        _deleteItem(item.id);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'indent',
                      child: Text(context.l10n.indent),
                    ),
                    PopupMenuItem(
                      value: 'outdent',
                      child: Text(context.l10n.outdent),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(context.l10n.delete),
                    ),
                  ],
                ),
              ),
            ),
          if (!_readOnly)
            ReorderableDragStartListener(
              key: ValueKey('checklist-drag-handle-${item.id}'),
              index: reorderIndex,
              child: SizedBox(
                height: firstLineExtent,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(
                      Icons.drag_indicator,
                      color: foregroundColor.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Dismissible(
      key: ValueKey('checklist-item-${item.id}'),
      direction: _readOnly || active || dragging
          ? DismissDirection.none
          : DismissDirection.endToStart,
      background: dragging
          ? null
          : Container(
              key: ValueKey('checklist-delete-surface-${item.id}'),
              margin: rowMargin,
              padding: const EdgeInsetsDirectional.only(end: 24),
              alignment: AlignmentDirectional.centerEnd,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
      onDismissed: (_) => _deleteItem(item.id),
      child: row,
    );
  }

  Widget _buildActiveRowEditor(
    RichChecklistItem item,
    Color backgroundColor,
    Color foregroundColor,
    Color placeholderColor, {
    required double verticalInset,
  }) {
    final controller = _rowController;
    return QuillEditor.basic(
      key: _rowQuillEditorKey,
      controller: controller,
      focusNode: _rowFocusNode,
      config: QuillEditorConfig(
        editorKey: _rowEditorKey,
        scrollable: false,
        padding: EdgeInsets.symmetric(vertical: verticalInset),
        placeholder: context.l10n.startWriting,
        showCursor: !_readOnly,
        enableInteractiveSelection: true,
        enableSelectionToolbar: true,
        textInputAction: TextInputAction.newline,
        onPerformAction: (action) {
          if (Theme.of(context).platform == TargetPlatform.android &&
              action == TextInputAction.newline) {
            _splitActiveItem();
          }
        },
        onKeyPressed: (event, node) => _handleRowKey(event),
        customStyles: buildQuillStyles(
          foregroundColor: foregroundColor,
          backgroundColor: backgroundColor,
          placeholderColor: placeholderColor,
        ),
        customLinkPrefixes: const ['audio://'],
      ),
    );
  }

  Widget _buildFormattingToolbar(Color backgroundColor) {
    return NoteEditorToolbar(
      key: const ValueKey('rich_checklist_toolbar'),
      controller: _rowController,
      focusNode: _rowFocusNode,
      readOnly: _readOnly,
      parentColor: backgroundColor,
      historyBinding: NoteEditorHistoryBinding(
        listenable: _history,
        canUndo: () => _history.canUndo,
        canRedo: () => _history.canRedo,
        undo: _undo,
        redo: _redo,
      ),
      showAttachments: false,
      showChecklist: false,
      showBlockLists: false,
      showIndent: false,
    );
  }
}

@immutable
class _ChecklistWorkspaceSnapshot {
  const _ChecklistWorkspaceSnapshot({
    required this.title,
    required this.content,
    required this.plainText,
    required this.bodyDelta,
    required this.collection,
    required this.entryReplacements,
    required this.selectionStart,
    required this.selectionEnd,
  });

  final String title;
  final String content;
  final String plainText;
  final List<Map<String, dynamic>> bodyDelta;
  final RichChecklistCollection collection;
  final List<ChecklistCollectionReplacement> entryReplacements;
  final int selectionStart;
  final int selectionEnd;
}

@immutable
class _ChecklistListEntry {
  const _ChecklistListEntry.item(this.item) : isCompletedHeader = false;
  const _ChecklistListEntry.completedHeader()
    : item = null,
      isCompletedHeader = true;

  final RichChecklistItem? item;
  final bool isCompletedHeader;

  String get identity => isCompletedHeader ? 'completed-header' : item!.id;
}

class _AnimatedChecklistBox extends StatelessWidget {
  const _AnimatedChecklistBox({
    super.key,
    required this.checked,
    required this.enabled,
    required this.color,
    required this.onChanged,
  });

  final bool checked;
  final bool enabled;
  final Color color;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: checked,
      enabled: enabled,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? () => onChanged(!checked) : null,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutBack,
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: checked ? color : Colors.transparent,
                border: Border.all(
                  color: checked ? color : color.withValues(alpha: 0.65),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(7),
              ),
              child: AnimatedScale(
                duration: const Duration(milliseconds: 160),
                scale: checked ? 1 : 0,
                child: Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: isDark(color) ? Colors.white : Colors.black,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RichChecklistText extends StatelessWidget {
  const _RichChecklistText({
    required this.item,
    required this.foregroundColor,
    required this.completed,
  });

  final RichChecklistItem item;
  final Color foregroundColor;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final direction = item.lineAttributes['direction'] == 'rtl'
        ? TextDirection.rtl
        : TextDirection.ltr;
    final alignment = switch (item.lineAttributes['align']) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => TextAlign.start,
    };
    final lineHeight = _parseNumber(item.lineAttributes['line-height']);
    final baseStyle = TextStyle(
      color: foregroundColor,
      fontSize: 16,
      height: lineHeight,
    );

    return Opacity(
      opacity: completed ? 0.58 : 1,
      child: RichText(
        textDirection: direction,
        textAlign: alignment,
        text: TextSpan(
          style: baseStyle,
          children: item.delta
              .toList()
              .map((operation) {
                final text = operation.data as String;
                return TextSpan(
                  text: text,
                  style: _styleForAttributes(
                    baseStyle,
                    operation.attributes,
                    completed,
                  ),
                );
              })
              .toList(growable: false),
        ),
      ),
    );
  }

  TextStyle _styleForAttributes(
    TextStyle base,
    Map<String, dynamic>? attributes,
    bool completed,
  ) {
    final attrs = attributes ?? const <String, dynamic>{};
    final decorations = <TextDecoration>[];
    if (attrs['underline'] == true) decorations.add(TextDecoration.underline);
    if (attrs['strike'] == true || completed) {
      decorations.add(TextDecoration.lineThrough);
    }
    final size = _parseNumber(attrs['size']);
    final script = attrs['script'];
    final resolvedSize = size ?? base.fontSize;
    return base.copyWith(
      fontWeight: attrs['bold'] == true ? FontWeight.bold : null,
      fontStyle: attrs['italic'] == true ? FontStyle.italic : null,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
      fontSize: script == 'sub' || script == 'super'
          ? (resolvedSize ?? 16) * 0.75
          : resolvedSize,
      fontFamily: attrs['code'] == true
          ? 'monospace'
          : attrs['font']?.toString(),
      color:
          _parseColor(attrs['color']) ??
          (attrs['link'] != null ? Colors.lightBlueAccent : base.color),
      backgroundColor:
          _parseColor(attrs['background']) ??
          (attrs['code'] == true ? Colors.black12 : null),
    );
  }
}

double? _parseNumber(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) {
    return double.tryParse(value.replaceAll(RegExp(r'[^0-9.]'), ''));
  }
  return null;
}

Color? _parseColor(Object? value) {
  if (value is! String) return null;
  var hex = value.trim().replaceFirst('#', '');
  if (hex.length == 3) {
    hex = hex.split('').map((part) => '$part$part').join();
  }
  if (hex.length == 6) hex = 'ff$hex';
  if (hex.length != 8) return null;
  final parsed = int.tryParse(hex, radix: 16);
  return parsed == null ? null : Color(parsed);
}
