import 'dart:async';

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
class NoteFindReplacementRequest {
  const NoteFindReplacementRequest({
    required this.plan,
    required this.revision,
  });

  final NoteSearchReplacementPlan plan;
  final int revision;
}

class NoteFindController extends ChangeNotifier {
  NoteFindController({
    required NoteFindSnapshot Function() snapshot,
    required ValueChanged<NoteSearchMatch> onMatchActivated,
    int Function()? currentRevision,
    NoteFindSearchRunner? searchRunner,
  }) : this._(
         snapshot: snapshot,
         onMatchActivated: onMatchActivated,
         currentRevision: currentRevision,
         searchRunner: searchRunner,
       );

  NoteFindController._({
    required this._snapshot,
    required this._onMatchActivated,
    required this._currentRevision,
    required this._searchRunner,
  }) {
    queryController.addListener(_handleQueryChanged);
  }

  static const int _backgroundSearchThreshold = 64 * 1024;
  static const int maxRenderedMatches = 2000;

  final NoteFindSnapshot Function() _snapshot;
  final ValueChanged<NoteSearchMatch> _onMatchActivated;
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
  NoteSearchResult _result = const NoteSearchResult();
  int _activeIndex = -1;

  bool get isOpen => _isOpen;
  bool get isSearching => _isSearching;
  bool get replaceExpanded => _replaceExpanded;
  bool get caseSensitive => _caseSensitive;
  bool get wholeWord => _wholeWord;
  NoteSearchMode get mode => _mode;
  NoteSearchError? get error => _result.error;
  List<NoteSearchMatch> get matches => _result.matches;
  int get activeIndex => _activeIndex;
  int get matchCount => _result.matches.length;
  bool get canNavigate => _result.matches.isNotEmpty && !_isSearching;
  bool get canReplace =>
      _mode != NoteSearchMode.smart && canNavigate && _result.error == null;

  NoteSearchMatch? get currentMatch =>
      _activeIndex >= 0 && _activeIndex < _result.matches.length
      ? _result.matches[_activeIndex]
      : null;

  NoteSearchQuery get query => NoteSearchQuery(
    text: queryController.text,
    mode: _mode,
    caseSensitive: _caseSensitive,
    wholeWord: _wholeWord,
  );

  List<NoteSearchMatch> get renderedMatches {
    if (_result.matches.length <= maxRenderedMatches) return _result.matches;
    if (_activeIndex < 0) {
      return _result.matches.take(maxRenderedMatches).toList(growable: false);
    }
    final before = maxRenderedMatches ~/ 2;
    var start = (_activeIndex - before).clamp(
      0,
      _result.matches.length - maxRenderedMatches,
    );
    final end = (start + maxRenderedMatches).clamp(0, _result.matches.length);
    start = (end - maxRenderedMatches).clamp(0, end);
    return _result.matches.sublist(start, end);
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
    _result = const NoteSearchResult();
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
    if (modeChanged) {
      _mode = NoteSearchMode.literal;
    }
    _replaceExpanded = true;
    notifyListeners();
    if (modeChanged) {
      scheduleSearch(immediate: true);
    }
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
    if (value == NoteSearchMode.smart) {
      _replaceExpanded = false;
    }
    notifyListeners();
    scheduleSearch(immediate: true);
  }

  void next() => _move(1);

  void previous() => _move(-1);

  void _move(int delta) {
    if (_result.matches.isEmpty) return;
    _activeIndex = (_activeIndex + delta) % _result.matches.length;
    if (_activeIndex < 0) _activeIndex += _result.matches.length;
    _anchorOffset = _result.matches[_activeIndex].start;
    notifyListeners();
    _onMatchActivated(_result.matches[_activeIndex]);
  }

  void refreshForDocumentChange({int? anchorOffset}) {
    if (!_isOpen) return;
    _anchorOffset = anchorOffset ?? currentMatch?.start ?? _anchorOffset;
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
    final currentQuery = query;
    final freshResult = await _search(snapshot.document, currentQuery);
    if (!_isOpen || requestGeneration != _generation) {
      return NoteFindReplacementRequest(
        plan: const NoteSearchReplacementPlan(),
        revision: snapshot.revision,
      );
    }
    if (!freshResult.isValid) {
      _result = freshResult;
      notifyListeners();
      return NoteFindReplacementRequest(
        plan: NoteSearchReplacementPlan(error: freshResult.error),
        revision: snapshot.revision,
      );
    }

    int? matchIndex;
    if (!replaceAll) {
      final active = currentMatch;
      if (active == null || freshResult.matches.isEmpty) {
        return NoteFindReplacementRequest(
          plan: const NoteSearchReplacementPlan(),
          revision: snapshot.revision,
        );
      }
      matchIndex = freshResult.matches.indexWhere(
        (match) => match.start == active.start && match.end == active.end,
      );
      if (matchIndex < 0) {
        matchIndex = freshResult.matches.indexWhere(
          (match) => match.start >= active.start,
        );
        if (matchIndex < 0) matchIndex = 0;
      }
    }

    final plan = _engine.buildReplacementPlan(
      document: snapshot.document,
      query: currentQuery,
      replacement: replacementController.text,
      matchIndex: matchIndex,
      searchResult: freshResult,
    );
    if (!plan.isValid) {
      _result = NoteSearchResult(error: plan.error);
      notifyListeners();
    }
    return NoteFindReplacementRequest(plan: plan, revision: snapshot.revision);
  }

  void anchorAfterReplacement(int offset) {
    _anchorOffset = offset;
    scheduleSearch(immediate: true);
  }

  void _handleQueryChanged() {
    if (_suppressQueryListener) return;
    scheduleSearch();
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

    final result = await _search(snapshot.document, currentQuery);

    if (!_isOpen ||
        searchGeneration != _generation ||
        (_currentRevision != null && snapshot.revision != _currentRevision())) {
      return;
    }
    _result = result;
    _isSearching = false;
    _activeIndex = _findInitialIndex(result.matches, _anchorOffset);
    notifyListeners();
    final active = currentMatch;
    if (active != null) _onMatchActivated(active);
  }

  Future<NoteSearchResult> _search(
    NoteSearchDocument document,
    NoteSearchQuery searchQuery,
  ) async {
    if (_searchRunner != null) {
      return _searchRunner(document, searchQuery);
    }
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

  int _findInitialIndex(List<NoteSearchMatch> matches, int anchor) {
    if (matches.isEmpty) return -1;
    final next = matches.indexWhere((match) => match.start >= anchor);
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
