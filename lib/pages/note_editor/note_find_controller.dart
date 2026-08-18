import 'dart:async';

import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/services/note_search_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

typedef NoteFindSnapshot = ({NoteSearchDocument document, int revision});
typedef NoteFindSearchRunner =
    Future<NoteSearchResult> Function(
      NoteSearchDocument document,
      NoteSearchQuery query,
    );

@immutable
class NoteFindTableSnapshot {
  const NoteFindTableSnapshot({required this.offset, required this.table});

  final int offset;
  final NoteTable table;
}

@immutable
class NoteFindTarget {
  NoteFindTarget.body(this.match) : documentOffset = match.start, cell = null;

  const NoteFindTarget.table({
    required this.match,
    required this.documentOffset,
    required this.cell,
  });

  final NoteSearchMatch match;
  final int documentOffset;
  final NoteTableCellAddress? cell;

  bool get isTableCell => cell != null;
}

@immutable
class NoteFindReplacementEdit {
  const NoteFindReplacementEdit({
    required this.target,
    required this.replacement,
  });

  final NoteFindTarget target;
  final String replacement;
}

@immutable
class NoteFindReplacementPlan {
  const NoteFindReplacementPlan({
    this.edits = const <NoteFindReplacementEdit>[],
    this.error,
  });

  final List<NoteFindReplacementEdit> edits;
  final NoteSearchError? error;

  bool get isValid => error == null;
}

@immutable
class NoteFindReplacementRequest {
  const NoteFindReplacementRequest({
    required this.plan,
    required this.revision,
  });

  final NoteFindReplacementPlan plan;
  final int revision;
}

class NoteFindController extends ChangeNotifier {
  NoteFindController({
    required NoteFindSnapshot Function() snapshot,
    ValueChanged<NoteSearchMatch>? onMatchActivated,
    ValueChanged<NoteFindTarget>? onTargetActivated,
    List<NoteFindTableSnapshot> Function()? tableSnapshot,
    int Function()? currentRevision,
    NoteFindSearchRunner? searchRunner,
  }) : this._(
         snapshot: snapshot,
         onMatchActivated: onMatchActivated,
         onTargetActivated: onTargetActivated,
         tableSnapshot: tableSnapshot,
         currentRevision: currentRevision,
         searchRunner: searchRunner,
       );

  NoteFindController._({
    required this._snapshot,
    required this._onMatchActivated,
    required this._onTargetActivated,
    required this._tableSnapshot,
    required this._currentRevision,
    required this._searchRunner,
  }) {
    queryController.addListener(_handleQueryChanged);
  }

  static const int _backgroundSearchThreshold = 64 * 1024;
  static const int maxRenderedMatches = 2000;

  final NoteFindSnapshot Function() _snapshot;
  final ValueChanged<NoteSearchMatch>? _onMatchActivated;
  final ValueChanged<NoteFindTarget>? _onTargetActivated;
  final List<NoteFindTableSnapshot> Function()? _tableSnapshot;
  final int Function()? _currentRevision;
  final NoteFindSearchRunner? _searchRunner;
  final NoteSearchEngine _engine = const NoteSearchEngine();

  final TextEditingController queryController = TextEditingController();
  final TextEditingController replacementController = TextEditingController();
  final FocusNode queryFocusNode = FocusNode(debugLabel: 'Find in note');
  final FocusNode replacementFocusNode = FocusNode(
    debugLabel: 'Replace in note',
  );

  Timer? _debounce;
  int _generation = 0;
  int _anchorOffset = 0;
  bool _suppressQueryListener = false;
  bool _isOpen = false;
  bool _isSearching = false;
  bool _replaceExpanded = false;
  bool _caseSensitive = false;
  bool _wholeWord = false;
  NoteSearchMode _mode = NoteSearchMode.literal;
  List<NoteFindTarget> _targets = const [];
  NoteSearchError? _error;
  int _activeIndex = -1;

  bool get isOpen => _isOpen;
  bool get isSearching => _isSearching;
  bool get replaceExpanded => _replaceExpanded;
  bool get caseSensitive => _caseSensitive;
  bool get wholeWord => _wholeWord;
  NoteSearchMode get mode => _mode;
  NoteSearchError? get error => _error;
  List<NoteSearchMatch> get matches =>
      _targets.map((target) => target.match).toList(growable: false);
  int get activeIndex => _activeIndex;
  int get matchCount => _targets.length;
  bool get canNavigate => _targets.isNotEmpty && !_isSearching;
  bool get canReplace =>
      _mode != NoteSearchMode.smart && canNavigate && _error == null;

  NoteFindTarget? get currentTarget =>
      _activeIndex >= 0 && _activeIndex < _targets.length
      ? _targets[_activeIndex]
      : null;

  NoteSearchMatch? get currentMatch => currentTarget?.match;
  NoteSearchMatch? get currentBodyMatch =>
      currentTarget?.cell == null ? currentTarget?.match : null;

  NoteSearchQuery get query => NoteSearchQuery(
    text: queryController.text,
    mode: _mode,
    caseSensitive: _caseSensitive,
    wholeWord: _wholeWord,
  );

  List<NoteFindTarget> get _renderedTargets {
    if (_targets.length <= maxRenderedMatches) return _targets;
    if (_activeIndex < 0) {
      return _targets.take(maxRenderedMatches).toList(growable: false);
    }
    final before = maxRenderedMatches ~/ 2;
    var start = (_activeIndex - before).clamp(
      0,
      _targets.length - maxRenderedMatches,
    );
    final end = (start + maxRenderedMatches).clamp(0, _targets.length);
    start = (end - maxRenderedMatches).clamp(0, end);
    return _targets.sublist(start, end);
  }

  List<NoteSearchMatch> get renderedMatches => _renderedTargets
      .where((target) => !target.isTableCell)
      .map((target) => target.match)
      .toList(growable: false);

  List<NoteTableTextMatch> get renderedTableMatches {
    final active = currentTarget;
    return _renderedTargets
        .where((target) => target.cell != null)
        .map(
          (target) => NoteTableTextMatch(
            address: target.cell!,
            start: target.match.start,
            end: target.match.end,
            active: identical(target, active),
          ),
        )
        .toList(growable: false);
  }

  void open({required int anchorOffset, String seed = ''}) {
    _anchorOffset = anchorOffset;
    _isOpen = true;
    _replaceExpanded = false;
    _setQueryText(seed);
    notifyListeners();
    scheduleSearch(immediate: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isOpen && queryFocusNode.canRequestFocus) {
        queryFocusNode.requestFocus();
        queryController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: queryController.text.length,
        );
      }
    });
  }

  void focusQuery() {
    if (!_isOpen) return;
    queryFocusNode.requestFocus();
    queryController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: queryController.text.length,
    );
  }

  void close() {
    _debounce?.cancel();
    _generation += 1;
    _isOpen = false;
    _isSearching = false;
    _replaceExpanded = false;
    _targets = const [];
    _error = null;
    _activeIndex = -1;
    _setQueryText('');
    replacementController.clear();
    queryFocusNode.unfocus();
    replacementFocusNode.unfocus();
    notifyListeners();
  }

  void toggleReplace() {
    if (_mode == NoteSearchMode.smart) return;
    _replaceExpanded = !_replaceExpanded;
    notifyListeners();
    if (_replaceExpanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_replaceExpanded && replacementFocusNode.canRequestFocus) {
          replacementFocusNode.requestFocus();
        }
      });
    }
  }

  void showReplace() {
    if (_replaceExpanded) return;
    final modeChanged = _mode == NoteSearchMode.smart;
    if (modeChanged) _mode = NoteSearchMode.literal;
    _replaceExpanded = true;
    notifyListeners();
    if (modeChanged) scheduleSearch(immediate: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_replaceExpanded && replacementFocusNode.canRequestFocus) {
        replacementFocusNode.requestFocus();
      }
    });
  }

  void setCaseSensitive(bool value) {
    if (_caseSensitive == value || _mode == NoteSearchMode.smart) return;
    _caseSensitive = value;
    notifyListeners();
    scheduleSearch(immediate: true);
  }

  void setWholeWord(bool value) {
    if (_wholeWord == value || _mode == NoteSearchMode.smart) return;
    _wholeWord = value;
    notifyListeners();
    scheduleSearch(immediate: true);
  }

  void setMode(NoteSearchMode value) {
    if (_mode == value) return;
    _mode = value;
    if (value == NoteSearchMode.smart) _replaceExpanded = false;
    notifyListeners();
    scheduleSearch(immediate: true);
  }

  void next() => _move(1);
  void previous() => _move(-1);

  void _move(int delta) {
    if (_targets.isEmpty) return;
    _activeIndex = (_activeIndex + delta) % _targets.length;
    if (_activeIndex < 0) _activeIndex += _targets.length;
    final target = _targets[_activeIndex];
    _anchorOffset = target.documentOffset;
    notifyListeners();
    _activateTarget(target);
  }

  void refreshForDocumentChange({int? anchorOffset}) {
    if (!_isOpen) return;
    _anchorOffset =
        anchorOffset ?? currentTarget?.documentOffset ?? _anchorOffset;
    scheduleSearch();
  }

  void scheduleSearch({bool immediate = false}) {
    if (!_isOpen) return;
    _debounce?.cancel();
    final searchGeneration = ++_generation;
    if (immediate) {
      unawaited(_runSearch(searchGeneration));
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(_runSearch(searchGeneration)),
    );
  }

  Future<NoteFindReplacementRequest> buildReplacementRequest({
    required bool replaceAll,
  }) async {
    final requestGeneration = _generation;
    final snapshot = _snapshot();
    final tables = _tableSnapshot?.call() ?? const [];
    final currentQuery = query;
    final fresh = await _searchTargets(snapshot.document, tables, currentQuery);
    if (!_isOpen || requestGeneration != _generation) {
      return NoteFindReplacementRequest(
        plan: const NoteFindReplacementPlan(),
        revision: snapshot.revision,
      );
    }
    if (fresh.error != null) {
      _targets = const [];
      _error = fresh.error;
      notifyListeners();
      return NoteFindReplacementRequest(
        plan: NoteFindReplacementPlan(error: fresh.error),
        revision: snapshot.revision,
      );
    }

    List<NoteFindTarget> selected;
    if (replaceAll) {
      selected = fresh.targets;
    } else {
      final active = currentTarget;
      if (active == null || fresh.targets.isEmpty) {
        return NoteFindReplacementRequest(
          plan: const NoteFindReplacementPlan(),
          revision: snapshot.revision,
        );
      }
      var index = fresh.targets.indexWhere(
        (target) => _sameTarget(target, active),
      );
      if (index < 0) {
        index = fresh.targets.indexWhere(
          (target) => target.documentOffset >= active.documentOffset,
        );
        if (index < 0) index = 0;
      }
      selected = [fresh.targets[index]];
    }

    final edits = <NoteFindReplacementEdit>[];
    for (final target in selected) {
      final plan = _engine.buildReplacementPlan(
        document: NoteSearchDocument(
          text: target.cell == null
              ? snapshot.document.text
              : _cellText(target.cell!, tables),
        ),
        query: currentQuery,
        replacement: replacementController.text,
        matchIndex: 0,
        searchResult: NoteSearchResult(matches: [target.match]),
      );
      if (!plan.isValid) {
        _error = plan.error;
        notifyListeners();
        return NoteFindReplacementRequest(
          plan: NoteFindReplacementPlan(error: plan.error),
          revision: snapshot.revision,
        );
      }
      if (plan.edits.isNotEmpty) {
        edits.add(
          NoteFindReplacementEdit(
            target: target,
            replacement: plan.edits.single.replacement,
          ),
        );
      }
    }
    return NoteFindReplacementRequest(
      plan: NoteFindReplacementPlan(edits: List.unmodifiable(edits)),
      revision: snapshot.revision,
    );
  }

  void anchorAfterReplacement(int offset) {
    _anchorOffset = offset;
    scheduleSearch(immediate: true);
  }

  void _handleQueryChanged() {
    if (!_suppressQueryListener) scheduleSearch();
  }

  void _setQueryText(String value) {
    _suppressQueryListener = true;
    queryController.text = value;
    _suppressQueryListener = false;
  }

  Future<void> _runSearch(int searchGeneration) async {
    if (!_isOpen) return;
    final snapshot = _snapshot();
    final currentQuery = query;
    _isSearching = true;
    notifyListeners();

    final result = await _searchTargets(
      snapshot.document,
      _tableSnapshot?.call() ?? const [],
      currentQuery,
    );

    if (!_isOpen ||
        searchGeneration != _generation ||
        (_currentRevision != null && snapshot.revision != _currentRevision())) {
      return;
    }
    _targets = result.targets;
    _error = result.error;
    _isSearching = false;
    _activeIndex = _findInitialIndex(_targets, _anchorOffset);
    notifyListeners();
    final active = currentTarget;
    if (active != null) _activateTarget(active);
  }

  Future<({List<NoteFindTarget> targets, NoteSearchError? error})>
  _searchTargets(
    NoteSearchDocument document,
    List<NoteFindTableSnapshot> tables,
    NoteSearchQuery searchQuery,
  ) async {
    final body = await _search(document, searchQuery);
    if (!body.isValid) {
      return (targets: const <NoteFindTarget>[], error: body.error);
    }
    final targets = <NoteFindTarget>[...body.matches.map(NoteFindTarget.body)];
    for (final snapshot in tables) {
      for (var row = 0; row < snapshot.table.rowCount; row++) {
        for (var column = 0; column < snapshot.table.columnCount; column++) {
          final result = _engine.search(
            NoteSearchDocument(text: snapshot.table.cellAt(row, column)),
            searchQuery,
          );
          if (!result.isValid) {
            return (targets: const <NoteFindTarget>[], error: result.error);
          }
          final address = NoteTableCellAddress(
            tableId: snapshot.table.id,
            row: row,
            column: column,
          );
          targets.addAll(
            result.matches.map(
              (match) => NoteFindTarget.table(
                match: match,
                documentOffset: snapshot.offset,
                cell: address,
              ),
            ),
          );
        }
      }
    }
    targets.sort((a, b) {
      final offset = a.documentOffset.compareTo(b.documentOffset);
      if (offset != 0) return offset;
      final aCell = a.cell;
      final bCell = b.cell;
      if (aCell == null || bCell == null) return aCell == null ? -1 : 1;
      final row = aCell.row.compareTo(bCell.row);
      if (row != 0) return row;
      final column = aCell.column.compareTo(bCell.column);
      if (column != 0) return column;
      return a.match.start.compareTo(b.match.start);
    });
    return (targets: List<NoteFindTarget>.unmodifiable(targets), error: null);
  }

  Future<NoteSearchResult> _search(
    NoteSearchDocument document,
    NoteSearchQuery searchQuery,
  ) async {
    if (_searchRunner != null) return _searchRunner(document, searchQuery);
    if (document.text.length < _backgroundSearchThreshold) {
      return _engine.search(document, searchQuery);
    }
    if (kIsWeb && searchQuery.mode != NoteSearchMode.regularExpression) {
      return _engine.searchCooperatively(document, searchQuery);
    }
    if (!kIsWeb) {
      return compute(
        runNoteSearch,
        NoteSearchRequest(document: document, query: searchQuery),
        debugLabel: 'note-search',
      );
    }
    return _engine.search(document, searchQuery);
  }

  void _activateTarget(NoteFindTarget target) {
    _onTargetActivated?.call(target);
    if (!target.isTableCell) _onMatchActivated?.call(target.match);
  }

  bool _sameTarget(NoteFindTarget a, NoteFindTarget b) =>
      a.cell == b.cell &&
      a.match.start == b.match.start &&
      a.match.end == b.match.end;

  String _cellText(
    NoteTableCellAddress address,
    List<NoteFindTableSnapshot> tables,
  ) {
    for (final snapshot in tables) {
      if (snapshot.table.id == address.tableId &&
          address.row < snapshot.table.rowCount &&
          address.column < snapshot.table.columnCount) {
        return snapshot.table.cellAt(address.row, address.column);
      }
    }
    return '';
  }

  int _findInitialIndex(List<NoteFindTarget> targets, int anchor) {
    if (targets.isEmpty) return -1;
    final next = targets.indexWhere(
      (target) => target.documentOffset >= anchor,
    );
    return next < 0 ? 0 : next;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    queryController.removeListener(_handleQueryChanged);
    queryController.dispose();
    replacementController.dispose();
    queryFocusNode.dispose();
    replacementFocusNode.dispose();
    super.dispose();
  }
}
