import 'dart:async';

import 'package:flutter/foundation.dart';

enum NoteSearchMode { literal, regularExpression, smart }

enum NoteSearchError {
  invalidRegularExpression,
  zeroLengthMatchesUnsupported,
  invalidReplacementReference,
}

@immutable
class NoteSearchQuery {
  const NoteSearchQuery({
    required this.text,
    this.mode = NoteSearchMode.literal,
    this.caseSensitive = false,
    this.wholeWord = false,
  });

  final String text;
  final NoteSearchMode mode;
  final bool caseSensitive;
  final bool wholeWord;

  bool get isEmpty => text.isEmpty;

  NoteSearchQuery copyWith({
    String? text,
    NoteSearchMode? mode,
    bool? caseSensitive,
    bool? wholeWord,
  }) {
    return NoteSearchQuery(
      text: text ?? this.text,
      mode: mode ?? this.mode,
      caseSensitive: caseSensitive ?? this.caseSensitive,
      wholeWord: wholeWord ?? this.wholeWord,
    );
  }
}

@immutable
class NoteSearchRange {
  const NoteSearchRange(this.start, this.end)
    : assert(start >= 0),
      assert(end >= start);

  final int start;
  final int end;

  bool intersects(int otherStart, int otherEnd) =>
      start < otherEnd && end > otherStart;
}

@immutable
class NoteSearchDocument {
  const NoteSearchDocument({
    required this.text,
    this.excludedRanges = const <NoteSearchRange>[],
  });

  factory NoteSearchDocument.fromDeltaJson(
    List<Map<String, dynamic>> operations,
  ) {
    final buffer = StringBuffer();
    final excluded = <NoteSearchRange>[];
    var offset = 0;

    for (final operation in operations) {
      final insert = operation['insert'];
      if (insert is String) {
        buffer.write(insert);
        offset += insert.length;
      } else if (insert != null) {
        buffer.write(_objectReplacementCharacter);
        excluded.add(NoteSearchRange(offset, offset + 1));
        offset += 1;
      }
    }

    var text = buffer.toString();
    if (text.endsWith('\n')) {
      text = text.substring(0, text.length - 1);
    }
    return NoteSearchDocument(
      text: text,
      excludedRanges: List.unmodifiable(excluded),
    );
  }

  static const String _objectReplacementCharacter = '\uFFFC';

  final String text;
  final List<NoteSearchRange> excludedRanges;

  bool intersectsExcludedRange(int start, int end) {
    for (final range in excludedRanges) {
      if (range.start >= end) return false;
      if (range.intersects(start, end)) return true;
    }
    return false;
  }
}

@immutable
class NoteSearchMatch {
  const NoteSearchMatch({
    required this.start,
    required this.end,
    this.score = 1,
    this.groups = const <String?>[],
    this.namedGroups = const <String, String?>{},
  }) : assert(start >= 0),
       assert(end >= start);

  final int start;
  final int end;
  final double score;
  final List<String?> groups;
  final Map<String, String?> namedGroups;

  int get length => end - start;
}

@immutable
class NoteSearchResult {
  const NoteSearchResult({
    this.matches = const <NoteSearchMatch>[],
    this.error,
  });

  final List<NoteSearchMatch> matches;
  final NoteSearchError? error;

  bool get isValid => error == null;
}

@immutable
class NoteSearchTextEdit {
  const NoteSearchTextEdit({
    required this.start,
    required this.end,
    required this.replacement,
  });

  final int start;
  final int end;
  final String replacement;

  int get replacedLength => end - start;
}

@immutable
class NoteSearchReplacementPlan {
  const NoteSearchReplacementPlan({
    this.edits = const <NoteSearchTextEdit>[],
    this.error,
  });

  final List<NoteSearchTextEdit> edits;
  final NoteSearchError? error;

  bool get isValid => error == null;
}

@immutable
class NoteSearchRequest {
  const NoteSearchRequest({required this.document, required this.query});

  final NoteSearchDocument document;
  final NoteSearchQuery query;
}

NoteSearchResult runNoteSearch(NoteSearchRequest request) =>
    const NoteSearchEngine().search(request.document, request.query);

class NoteSearchEngine {
  const NoteSearchEngine();

  static final RegExp _wordCharacter = RegExp(
    r'^[\p{L}\p{N}_]$',
    unicode: true,
  );
  static final RegExp _wordPattern = RegExp(r'[\p{L}\p{N}_]+', unicode: true);
  static final RegExp _namedGroupPattern = RegExp(
    r'\(\?<([A-Za-z][A-Za-z0-9_]*)>',
  );

  NoteSearchResult search(NoteSearchDocument document, NoteSearchQuery query) {
    if (query.isEmpty || document.text.isEmpty) {
      return const NoteSearchResult();
    }
    return switch (query.mode) {
      NoteSearchMode.literal ||
      NoteSearchMode.regularExpression => _searchExpression(document, query),
      NoteSearchMode.smart => _searchSmart(document, query.text),
    };
  }

  Future<NoteSearchResult> searchCooperatively(
    NoteSearchDocument document,
    NoteSearchQuery query, {
    int linesPerBatch = 80,
  }) async {
    if (query.isEmpty || document.text.isEmpty) {
      return const NoteSearchResult();
    }
    if (query.mode == NoteSearchMode.regularExpression) {
      return search(document, query);
    }

    final matches = <NoteSearchMatch>[];
    var lineStart = 0;
    var processedLines = 0;
    while (lineStart <= document.text.length) {
      final newline = document.text.indexOf('\n', lineStart);
      final lineEnd = newline < 0 ? document.text.length : newline;
      final lineDocument = NoteSearchDocument(
        text: document.text.substring(lineStart, lineEnd),
        excludedRanges: document.excludedRanges
            .where((range) => range.start >= lineStart && range.end <= lineEnd)
            .map(
              (range) => NoteSearchRange(
                range.start - lineStart,
                range.end - lineStart,
              ),
            )
            .toList(growable: false),
      );
      final lineResult = query.mode == NoteSearchMode.smart
          ? _searchSmart(lineDocument, query.text)
          : _searchExpression(lineDocument, query);
      if (!lineResult.isValid) return lineResult;
      matches.addAll(
        lineResult.matches.map(
          (match) => NoteSearchMatch(
            start: match.start + lineStart,
            end: match.end + lineStart,
            score: match.score,
            groups: match.groups,
            namedGroups: match.namedGroups,
          ),
        ),
      );

      if (newline < 0) break;
      lineStart = newline + 1;
      processedLines += 1;
      if (processedLines % linesPerBatch == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return NoteSearchResult(matches: List.unmodifiable(matches));
  }

  NoteSearchReplacementPlan buildReplacementPlan({
    required NoteSearchDocument document,
    required NoteSearchQuery query,
    required String replacement,
    int? matchIndex,
    NoteSearchResult? searchResult,
  }) {
    if (query.mode == NoteSearchMode.smart) {
      return const NoteSearchReplacementPlan();
    }
    final result = searchResult ?? search(document, query);
    if (!result.isValid) {
      return NoteSearchReplacementPlan(error: result.error);
    }
    if (matchIndex != null &&
        (matchIndex < 0 || matchIndex >= result.matches.length)) {
      return const NoteSearchReplacementPlan();
    }

    final matches = matchIndex == null
        ? result.matches
        : <NoteSearchMatch>[result.matches[matchIndex]];
    final edits = <NoteSearchTextEdit>[];
    for (final match in matches) {
      final expanded = query.mode == NoteSearchMode.regularExpression
          ? _expandRegexReplacement(replacement, match)
          : (value: replacement, error: null);
      if (expanded.error != null) {
        return NoteSearchReplacementPlan(error: expanded.error);
      }
      edits.add(
        NoteSearchTextEdit(
          start: match.start,
          end: match.end,
          replacement: expanded.value,
        ),
      );
    }
    return NoteSearchReplacementPlan(edits: List.unmodifiable(edits));
  }

  NoteSearchResult _searchExpression(
    NoteSearchDocument document,
    NoteSearchQuery query,
  ) {
    late final RegExp expression;
    try {
      expression = RegExp(
        query.mode == NoteSearchMode.literal
            ? RegExp.escape(query.text)
            : query.text,
        caseSensitive: query.caseSensitive,
        multiLine: true,
        unicode: true,
      );
    } on FormatException {
      return const NoteSearchResult(
        error: NoteSearchError.invalidRegularExpression,
      );
    }

    final namedGroupNames = query.mode == NoteSearchMode.regularExpression
        ? _extractNamedGroupNames(query.text)
        : const <String>[];
    final matches = <NoteSearchMatch>[];
    var encounteredZeroLength = false;
    for (final match in expression.allMatches(document.text)) {
      if (match.start == match.end) {
        encounteredZeroLength = true;
        continue;
      }
      if (query.wholeWord &&
          !_hasWholeWordBoundaries(document.text, match.start, match.end)) {
        continue;
      }
      if (document.intersectsExcludedRange(match.start, match.end)) continue;

      final groups = List<String?>.generate(
        match.groupCount + 1,
        match.group,
        growable: false,
      );
      final namedGroups = <String, String?>{};
      for (final name in namedGroupNames) {
        try {
          namedGroups[name] = match.namedGroup(name);
        } on ArgumentError {
          // The pattern parser is intentionally conservative. Ignore strings
          // that looked like group declarations but were not actual groups.
        }
      }
      matches.add(
        NoteSearchMatch(
          start: match.start,
          end: match.end,
          groups: groups,
          namedGroups: Map.unmodifiable(namedGroups),
        ),
      );
    }
    if (matches.isEmpty && encounteredZeroLength) {
      return const NoteSearchResult(
        error: NoteSearchError.zeroLengthMatchesUnsupported,
      );
    }
    return NoteSearchResult(matches: List.unmodifiable(matches));
  }

  NoteSearchResult _searchSmart(NoteSearchDocument document, String rawQuery) {
    final queryWords = _wordPattern
        .allMatches(rawQuery.toLowerCase())
        .map((match) => match.group(0)!)
        .toList(growable: false);
    if (queryWords.isEmpty) return const NoteSearchResult();

    final candidates = <NoteSearchMatch>[];
    var lineStart = 0;
    while (lineStart <= document.text.length) {
      final newline = document.text.indexOf('\n', lineStart);
      final lineEnd = newline < 0 ? document.text.length : newline;
      final line = document.text.substring(lineStart, lineEnd);
      final words = _wordPattern
          .allMatches(line)
          .map(
            (match) => _SearchWord(
              text: match.group(0)!.toLowerCase(),
              start: lineStart + match.start,
              end: lineStart + match.end,
            ),
          )
          .toList(growable: false);
      _collectSmartMatches(document, queryWords, words, candidates);
      if (newline < 0) break;
      lineStart = newline + 1;
    }

    candidates.sort((a, b) {
      final startComparison = a.start.compareTo(b.start);
      if (startComparison != 0) return startComparison;
      final scoreComparison = b.score.compareTo(a.score);
      if (scoreComparison != 0) return scoreComparison;
      return a.end.compareTo(b.end);
    });
    final deduplicated = <NoteSearchMatch>[];
    for (final candidate in candidates) {
      if (deduplicated.isEmpty || deduplicated.last.end <= candidate.start) {
        deduplicated.add(candidate);
        continue;
      }
      if (candidate.score > deduplicated.last.score) {
        deduplicated[deduplicated.length - 1] = candidate;
      }
    }
    deduplicated.sort((a, b) => a.start.compareTo(b.start));
    return NoteSearchResult(matches: List.unmodifiable(deduplicated));
  }

  void _collectSmartMatches(
    NoteSearchDocument document,
    List<String> queryWords,
    List<_SearchWord> words,
    List<NoteSearchMatch> output,
  ) {
    for (
      var firstWordIndex = 0;
      firstWordIndex < words.length;
      firstWordIndex += 1
    ) {
      final firstScore = _smartTokenScore(
        queryWords.first,
        words[firstWordIndex].text,
      );
      if (firstScore == null) continue;

      var states = <int, _SmartMatchState>{
        firstWordIndex: _SmartMatchState(score: firstScore, skippedWords: 0),
      };
      for (
        var queryIndex = 1;
        queryIndex < queryWords.length;
        queryIndex += 1
      ) {
        final nextStates = <int, _SmartMatchState>{};
        for (final entry in states.entries) {
          final maxNextIndex = (entry.key + 3).clamp(0, words.length - 1);
          for (
            var nextWordIndex = entry.key + 1;
            nextWordIndex <= maxNextIndex;
            nextWordIndex += 1
          ) {
            final tokenScore = _smartTokenScore(
              queryWords[queryIndex],
              words[nextWordIndex].text,
            );
            if (tokenScore == null) continue;
            final candidate = _SmartMatchState(
              score: entry.value.score + tokenScore,
              skippedWords:
                  entry.value.skippedWords + (nextWordIndex - entry.key - 1),
            );
            final existing = nextStates[nextWordIndex];
            if (existing == null ||
                candidate.adjustedScore > existing.adjustedScore) {
              nextStates[nextWordIndex] = candidate;
            }
          }
        }
        states = nextStates;
        if (states.isEmpty) break;
      }

      for (final entry in states.entries) {
        final start = words[firstWordIndex].start;
        final end = words[entry.key].end;
        if (document.intersectsExcludedRange(start, end)) continue;
        output.add(
          NoteSearchMatch(
            start: start,
            end: end,
            score:
                (entry.value.score / queryWords.length) -
                (entry.value.skippedWords * 0.025),
          ),
        );
      }
    }
  }

  double? _smartTokenScore(String query, String candidate) {
    if (query == candidate) return 1;
    if (candidate.startsWith(query)) {
      return (0.94 - ((candidate.length - query.length) * 0.005)).clamp(
        0.72,
        0.94,
      );
    }

    final queryLength = query.runes.length;
    final allowedDistance = queryLength <= 3 ? 0 : (queryLength <= 7 ? 1 : 2);
    if (allowedDistance > 0 &&
        (query.runes.length - candidate.runes.length).abs() <=
            allowedDistance) {
      final distance = _boundedDamerauLevenshtein(
        query.runes.toList(growable: false),
        candidate.runes.toList(growable: false),
        allowedDistance,
      );
      if (distance <= allowedDistance) {
        return 0.86 - (distance * 0.06);
      }
    }

    final subsequenceDensity = _subsequenceDensity(query, candidate);
    if (query.runes.length >= 2 && subsequenceDensity != null) {
      return 0.62 + (subsequenceDensity * 0.2);
    }
    return null;
  }

  int _boundedDamerauLevenshtein(
    List<int> source,
    List<int> target,
    int limit,
  ) {
    if ((source.length - target.length).abs() > limit) return limit + 1;
    var previousPrevious = <int>[];
    var previous = List<int>.generate(target.length + 1, (index) => index);
    for (var sourceIndex = 1; sourceIndex <= source.length; sourceIndex += 1) {
      final current = List<int>.filled(target.length + 1, 0);
      current[0] = sourceIndex;
      var rowMinimum = current[0];
      for (
        var targetIndex = 1;
        targetIndex <= target.length;
        targetIndex += 1
      ) {
        final substitutionCost =
            source[sourceIndex - 1] == target[targetIndex - 1] ? 0 : 1;
        var value = _minimum3(
          current[targetIndex - 1] + 1,
          previous[targetIndex] + 1,
          previous[targetIndex - 1] + substitutionCost,
        );
        if (sourceIndex > 1 &&
            targetIndex > 1 &&
            source[sourceIndex - 1] == target[targetIndex - 2] &&
            source[sourceIndex - 2] == target[targetIndex - 1]) {
          final transposition =
              previousPrevious[targetIndex - 2] + substitutionCost;
          if (transposition < value) value = transposition;
        }
        current[targetIndex] = value;
        if (value < rowMinimum) rowMinimum = value;
      }
      if (rowMinimum > limit) return limit + 1;
      previousPrevious = previous;
      previous = current;
    }
    return previous[target.length];
  }

  int _minimum3(int first, int second, int third) {
    var result = first < second ? first : second;
    if (third < result) result = third;
    return result;
  }

  double? _subsequenceDensity(String query, String candidate) {
    final queryRunes = query.runes.toList(growable: false);
    final candidateRunes = candidate.runes.toList(growable: false);
    var queryIndex = 0;
    var firstMatch = -1;
    var lastMatch = -1;
    for (
      var candidateIndex = 0;
      candidateIndex < candidateRunes.length && queryIndex < queryRunes.length;
      candidateIndex += 1
    ) {
      if (candidateRunes[candidateIndex] != queryRunes[queryIndex]) continue;
      firstMatch = firstMatch < 0 ? candidateIndex : firstMatch;
      lastMatch = candidateIndex;
      queryIndex += 1;
    }
    if (queryIndex != queryRunes.length) return null;
    final span = lastMatch - firstMatch + 1;
    return queryRunes.length / span;
  }

  bool _hasWholeWordBoundaries(String text, int start, int end) {
    final previous = _codePointBefore(text, start);
    final next = _codePointAt(text, end);
    return (previous == null || !_isWordCodePoint(previous)) &&
        (next == null || !_isWordCodePoint(next));
  }

  int? _codePointBefore(String text, int offset) {
    if (offset <= 0) return null;
    final last = text.codeUnitAt(offset - 1);
    if (_isLowSurrogate(last) && offset >= 2) {
      final first = text.codeUnitAt(offset - 2);
      if (_isHighSurrogate(first)) {
        return 0x10000 + ((first - 0xD800) << 10) + (last - 0xDC00);
      }
    }
    return last;
  }

  int? _codePointAt(String text, int offset) {
    if (offset >= text.length) return null;
    final first = text.codeUnitAt(offset);
    if (_isHighSurrogate(first) && offset + 1 < text.length) {
      final last = text.codeUnitAt(offset + 1);
      if (_isLowSurrogate(last)) {
        return 0x10000 + ((first - 0xD800) << 10) + (last - 0xDC00);
      }
    }
    return first;
  }

  bool _isHighSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;

  bool _isLowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;

  bool _isWordCodePoint(int value) =>
      _wordCharacter.hasMatch(String.fromCharCode(value));

  List<String> _extractNamedGroupNames(String pattern) => _namedGroupPattern
      .allMatches(pattern)
      .map((match) => match.group(1)!)
      .toSet()
      .toList(growable: false);

  ({String value, NoteSearchError? error}) _expandRegexReplacement(
    String template,
    NoteSearchMatch match,
  ) {
    final output = StringBuffer();
    for (var index = 0; index < template.length; index += 1) {
      final character = template[index];
      if (character == r'\') {
        if (index + 1 >= template.length) {
          output.write(r'\');
          continue;
        }
        final escaped = template[++index];
        output.write(switch (escaped) {
          'n' => '\n',
          't' => '\t',
          r'\' => r'\',
          r'$' => r'$',
          _ => escaped,
        });
        continue;
      }
      if (character != r'$' || index + 1 >= template.length) {
        output.write(character);
        continue;
      }

      final next = template[index + 1];
      if (next == r'$') {
        output.write(r'$');
        index += 1;
        continue;
      }
      if (next == '{') {
        final close = template.indexOf('}', index + 2);
        if (close < 0) {
          return (
            value: '',
            error: NoteSearchError.invalidReplacementReference,
          );
        }
        final name = template.substring(index + 2, close);
        if (!match.namedGroups.containsKey(name)) {
          return (
            value: '',
            error: NoteSearchError.invalidReplacementReference,
          );
        }
        output.write(match.namedGroups[name] ?? '');
        index = close;
        continue;
      }
      final firstDigit = int.tryParse(next);
      if (firstDigit != null) {
        var groupIndex = firstDigit;
        var consumed = 1;
        if (index + 2 < template.length) {
          final secondDigit = int.tryParse(template[index + 2]);
          if (secondDigit != null) {
            final candidate = (firstDigit * 10) + secondDigit;
            if (candidate < match.groups.length) {
              groupIndex = candidate;
              consumed = 2;
            }
          }
        }
        if (groupIndex >= match.groups.length) {
          return (
            value: '',
            error: NoteSearchError.invalidReplacementReference,
          );
        }
        output.write(match.groups[groupIndex] ?? '');
        index += consumed;
        continue;
      }
      output.write(character);
    }
    return (value: output.toString(), error: null);
  }
}

@immutable
class _SearchWord {
  const _SearchWord({
    required this.text,
    required this.start,
    required this.end,
  });

  final String text;
  final int start;
  final int end;
}

@immutable
class _SmartMatchState {
  const _SmartMatchState({required this.score, required this.skippedWords});

  final double score;
  final int skippedWords;

  double get adjustedScore => score - (skippedWords * 0.025);
}
