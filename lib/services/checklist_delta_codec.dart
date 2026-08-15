import 'dart:convert';

import 'package:better_keep/models/rich_checklist.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:uuid/uuid.dart';

export 'package:better_keep/models/rich_checklist.dart'
    show ChecklistDeltaFailureReason;

class ChecklistDeltaDecodeResult {
  const ChecklistDeltaDecodeResult._({
    this.document,
    this.failureReason,
    this.reason,
  });

  factory ChecklistDeltaDecodeResult.success(RichChecklistDocument document) =>
      ChecklistDeltaDecodeResult._(document: document);

  factory ChecklistDeltaDecodeResult.failure(
    ChecklistDeltaFailureReason failureReason,
    String reason,
  ) => ChecklistDeltaDecodeResult._(
    failureReason: failureReason,
    reason: reason,
  );

  final RichChecklistDocument? document;
  final ChecklistDeltaFailureReason? failureReason;
  final String? reason;

  bool get isEligible => document != null;
}

class ChecklistBlockLookupResult {
  const ChecklistBlockLookupResult._({
    this.slice,
    this.startOffset,
    this.endOffset,
    this.failureReason,
    this.reason,
  });

  const ChecklistBlockLookupResult.none()
    : slice = null,
      startOffset = null,
      endOffset = null,
      failureReason = null,
      reason = null;

  factory ChecklistBlockLookupResult.eligible(ChecklistBlockSlice slice) =>
      ChecklistBlockLookupResult._(
        slice: slice,
        startOffset: slice.startOffset,
        endOffset: slice.endOffset,
      );

  factory ChecklistBlockLookupResult.ineligible({
    required int startOffset,
    required int endOffset,
    required ChecklistDeltaFailureReason failureReason,
    required String reason,
  }) => ChecklistBlockLookupResult._(
    startOffset: startOffset,
    endOffset: endOffset,
    failureReason: failureReason,
    reason: reason,
  );

  final ChecklistBlockSlice? slice;
  final int? startOffset;
  final int? endOffset;
  final ChecklistDeltaFailureReason? failureReason;
  final String? reason;

  bool get isChecklistLine => startOffset != null;
  bool get isEligible => slice != null;
  String? get identity => slice?.identity;
}

class ChecklistBlockSpliceResult {
  ChecklistBlockSpliceResult({
    required List<Map<String, dynamic>> bodyDelta,
    required List<Map<String, dynamic>> replacementDelta,
    required this.selectionStart,
    required this.selectionEnd,
    this.block,
  }) : bodyDelta = List.unmodifiable(_copyOperations(bodyDelta)),
       replacementDelta = List.unmodifiable(_copyOperations(replacementDelta));

  final List<Map<String, dynamic>> bodyDelta;
  final List<Map<String, dynamic>> replacementDelta;
  final ChecklistBlockSlice? block;
  final int selectionStart;
  final int selectionEnd;
}

class ChecklistCombinedDelta {
  ChecklistCombinedDelta({
    required this.title,
    required List<Map<String, dynamic>> bodyDelta,
  }) : bodyDelta = List.unmodifiable(_copyOperations(bodyDelta));

  final String title;
  final List<Map<String, dynamic>> bodyDelta;
}

class ChecklistBlockStaleException implements Exception {
  const ChecklistBlockStaleException();

  @override
  String toString() => 'The checklist block changed before it was saved';
}

class ChecklistDeltaCodec {
  ChecklistDeltaCodec({ChecklistItemIdFactory? newId})
    : _newId = newId ?? const Uuid().v4;

  final ChecklistItemIdFactory _newId;

  static const _incompatibleBlockKeys = {'header', 'code-block', 'blockquote'};

  List<ChecklistBlockLookupResult> scanChecklistBlocks(Document document) {
    final lines = _scanLines(document.toDelta());
    final blocks = <ChecklistBlockLookupResult>[];
    final checklistLines = <_ScannedDeltaLine>[];

    void finishBlock() {
      if (checklistLines.isEmpty) return;
      blocks.add(_decodeScannedBlock(checklistLines));
      checklistLines.clear();
    }

    for (final line in lines) {
      if (line.isChecklist) {
        checklistLines.add(line);
      } else {
        finishBlock();
      }
    }
    finishBlock();
    return blocks;
  }

  ChecklistBlockLookupResult findChecklistBlockAt(
    Document document,
    int offset,
  ) {
    if (offset < 0) return const ChecklistBlockLookupResult.none();
    for (final block in scanChecklistBlocks(document)) {
      if (offset >= block.startOffset! && offset < block.endOffset!) {
        return block;
      }
    }
    return const ChecklistBlockLookupResult.none();
  }

  ChecklistBlockEditSession? createEditSession({
    required String title,
    required Document document,
    required int caretOffset,
    required int selectionStart,
    required int selectionEnd,
  }) {
    final block = findChecklistBlockAt(document, caretOffset).slice;
    if (block == null) return null;
    return ChecklistBlockEditSession(
      title: title,
      bodyDelta: document.toDelta().toJson(),
      block: block,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd,
      blockOrdinal: checklistBlockOrdinal(document, block),
    );
  }

  ChecklistCollectionEditSession? createCollectionEditSession({
    required String title,
    required Document document,
    required int selectionStart,
    required int selectionEnd,
  }) {
    final bodyDelta = document.toDelta().toJson();
    final lookups = scanChecklistBlocks(document);
    if (lookups.isEmpty) return null;
    final lines = _scanLines(document.toDelta());
    final sections = <RichChecklistSection>[];
    var contextStart = 0;

    for (var ordinal = 0; ordinal < lookups.length; ordinal++) {
      final lookup = lookups[ordinal];
      final startOffset = lookup.startOffset!;
      final endOffset = lookup.endOffset!;
      final sourceDelta = document
          .toDelta()
          .slice(startOffset, endOffset)
          .toJson();
      final sourceFingerprint = fingerprintOperations(sourceDelta);
      final progress = checklistProgressForOperations(sourceDelta);
      final contextLabel = _contextLabelForBlock(
        lines: lines,
        startOffset: contextStart,
        endOffset: startOffset,
      );
      final block = lookup.slice;
      sections.add(
        RichChecklistSection(
          id: _sectionId(ordinal, sourceFingerprint),
          ordinal: ordinal,
          startOffset: startOffset,
          endOffset: endOffset,
          sourceDelta: sourceDelta,
          sourceFingerprint: sourceFingerprint,
          contextLabel: contextLabel,
          block: block,
          document: block?.document,
          failureReason: lookup.failureReason,
          failureMessage: lookup.reason,
          checkedCount: progress.checked,
          totalCount: progress.total,
        ),
      );
      contextStart = endOffset;
    }

    return ChecklistCollectionEditSession(
      title: title,
      bodyDelta: bodyDelta,
      collection: RichChecklistCollection(sections),
      selectionStart: selectionStart,
      selectionEnd: selectionEnd,
    );
  }

  ({int checked, int total}) checklistProgress(Document document) =>
      checklistProgressForOperations(document.toDelta().toJson());

  ({int checked, int total}) checklistProgressForOperations(
    List<Map<String, dynamic>> operations,
  ) {
    var checked = 0;
    var total = 0;
    for (final operation in Delta.fromJson(operations).toList()) {
      if (!operation.isInsert || operation.data is! String) continue;
      final text = operation.data as String;
      if (!text.contains('\n')) continue;
      final list = operation.attributes?[Attribute.list.key];
      if (list != Attribute.checked.value &&
          list != Attribute.unchecked.value) {
        continue;
      }
      final lineCount = '\n'.allMatches(text).length;
      total += lineCount;
      if (list == Attribute.checked.value) checked += lineCount;
    }
    return (checked: checked, total: total);
  }

  ChecklistCollectionSpliceResult replaceCollectionDocuments({
    required List<Map<String, dynamic>> bodyDelta,
    required RichChecklistCollection collection,
  }) {
    final source = Delta.fromJson(bodyDelta);
    final eligible = collection.sections
        .where((section) => section.isEligible)
        .toList(growable: false);

    for (final section in eligible) {
      final currentSlice = source
          .slice(section.startOffset, section.endOffset)
          .toJson();
      if (fingerprintOperations(currentSlice) != section.sourceFingerprint) {
        throw const ChecklistBlockStaleException();
      }
    }

    final replacements = eligible
        .map(
          (section) => ChecklistCollectionReplacement(
            sectionId: section.id,
            startOffset: section.startOffset,
            sourceLength: section.length,
            sourceFingerprint: section.sourceFingerprint,
            replacementDelta: encodeBlock(
              section.document!,
              baseIndent: section.block!.baseIndent,
            ),
          ),
        )
        .toList(growable: false);

    var updated = source;
    final descending = [...replacements]
      ..sort((left, right) => right.startOffset.compareTo(left.startOffset));
    for (final replacement in descending) {
      updated = updated
          .slice(0, replacement.startOffset)
          .concat(Delta.fromJson(replacement.replacementDelta))
          .concat(
            updated.slice(replacement.startOffset + replacement.sourceLength),
          );
    }

    final normalizedBody = documentFromJsonSafe(
      updated.toJson(),
    ).toDelta().toJson();
    final rescanned = createCollectionEditSession(
      title: '',
      document: documentFromJsonSafe(normalizedBody),
      selectionStart: 0,
      selectionEnd: 0,
    );
    if (rescanned == null ||
        rescanned.collection.sections.length != collection.sections.length) {
      throw StateError('Encoded checklist collection is not decodable');
    }

    final rebased = <RichChecklistSection>[];
    for (var index = 0; index < collection.sections.length; index++) {
      final previous = collection.sections[index];
      final next = rescanned.collection.sections[index];
      if (previous.isEligible != next.isEligible) {
        throw StateError('Checklist section eligibility changed after encode');
      }
      if (!previous.isEligible) {
        rebased.add(
          next.rebase(
            startOffset: next.startOffset,
            endOffset: next.endOffset,
            sourceDelta: next.sourceDelta,
            sourceFingerprint: next.sourceFingerprint,
            contextLabel: next.contextLabel,
            failureReason: next.failureReason,
            failureMessage: next.failureMessage,
            checkedCount: next.checkedCount,
            totalCount: next.totalCount,
          ),
        );
        continue;
      }
      final block = next.block!.copyWith(document: previous.document);
      rebased.add(
        RichChecklistSection(
          id: previous.id,
          ordinal: previous.ordinal,
          startOffset: next.startOffset,
          endOffset: next.endOffset,
          sourceDelta: next.sourceDelta,
          sourceFingerprint: next.sourceFingerprint,
          contextLabel: next.contextLabel,
          block: block,
          document: previous.document,
          checkedCount: previous.document!.items
              .where((item) => item.checked)
              .length,
          totalCount: previous.document!.items.length,
        ),
      );
    }

    return ChecklistCollectionSpliceResult(
      bodyDelta: normalizedBody,
      collection: RichChecklistCollection(rebased),
      replacements: replacements,
    );
  }

  Delta buildCollectionTransaction({
    required List<Map<String, dynamic>> currentBodyDelta,
    required List<ChecklistCollectionReplacement> replacements,
  }) {
    final source = Delta.fromJson(currentBodyDelta);
    final ordered = [...replacements]
      ..sort((left, right) => left.startOffset.compareTo(right.startOffset));
    final transaction = Delta();
    var cursor = 0;
    for (final replacement in ordered) {
      if (replacement.startOffset < cursor) {
        throw ArgumentError('Checklist replacements overlap');
      }
      final currentSlice = source
          .slice(
            replacement.startOffset,
            replacement.startOffset + replacement.sourceLength,
          )
          .toJson();
      if (fingerprintOperations(currentSlice) !=
          replacement.sourceFingerprint) {
        throw const ChecklistBlockStaleException();
      }
      if (fingerprintOperations(currentSlice) ==
          fingerprintOperations(replacement.replacementDelta)) {
        continue;
      }
      final retained = replacement.startOffset - cursor;
      if (retained > 0) transaction.retain(retained);
      if (replacement.sourceLength > 0) {
        transaction.delete(replacement.sourceLength);
      }
      for (final operation in Delta.fromJson(
        replacement.replacementDelta,
      ).toList()) {
        transaction.push(operation);
      }
      cursor = replacement.startOffset + replacement.sourceLength;
    }
    return transaction;
  }

  ChecklistBlockLookupResult checklistBlockAtOrdinal(
    Document document,
    int ordinal,
  ) {
    final blocks = scanChecklistBlocks(document);
    if (ordinal < 0 || ordinal >= blocks.length) {
      return const ChecklistBlockLookupResult.none();
    }
    return blocks[ordinal];
  }

  int checklistBlockOrdinal(Document document, ChecklistBlockSlice slice) {
    final blocks = scanChecklistBlocks(document);
    for (var index = 0; index < blocks.length; index++) {
      if (blocks[index].slice?.sourceFingerprint == slice.sourceFingerprint &&
          blocks[index].startOffset == slice.startOffset) {
        return index;
      }
    }
    return 0;
  }

  ChecklistBlockSpliceResult replaceBlockDocument({
    required List<Map<String, dynamic>> bodyDelta,
    required ChecklistBlockSlice sourceBlock,
    required RichChecklistDocument document,
    int? selectionStart,
    int? selectionEnd,
  }) {
    final replacement = encodeBlock(
      document,
      baseIndent: sourceBlock.baseIndent,
    );
    final spliced = _spliceBlock(
      bodyDelta: bodyDelta,
      sourceBlock: sourceBlock,
      replacementDelta: replacement,
    );
    final updatedBody = documentFromJsonSafe(spliced).toDelta().toJson();
    final updatedDocument = documentFromJsonSafe(updatedBody);
    final lookup = findChecklistBlockAt(
      updatedDocument,
      sourceBlock.startOffset,
    );
    if (!lookup.isEligible) {
      throw StateError('Encoded checklist block is not decodable');
    }
    final fallbackOffset =
        sourceBlock.startOffset +
        (replacementDeltaLength(replacement) - 1).clamp(0, 1 << 30);
    return ChecklistBlockSpliceResult(
      bodyDelta: updatedBody,
      replacementDelta: replacement,
      block: lookup.slice,
      selectionStart: selectionStart ?? fallbackOffset,
      selectionEnd: selectionEnd ?? selectionStart ?? fallbackOffset,
    );
  }

  ChecklistCombinedDelta? tryParseCombinedJson(String? content) {
    if (content == null || content.isEmpty) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is! List) return null;
      var bodyStart = 0;
      var foundTitle = false;
      final title = StringBuffer();
      for (var index = 0; index < decoded.length; index++) {
        final raw = decoded[index];
        if (raw is! Map) return null;
        final attributes = raw['attributes'];
        if (raw['insert'] == '\n' &&
            attributes is Map &&
            attributes[Attribute.header.key] == 1) {
          bodyStart = index + 1;
          foundTitle = true;
          break;
        }
        if (raw['insert'] is String) title.write(raw['insert']);
      }
      final body = decoded
          .sublist(bodyStart)
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(growable: false);
      return ChecklistCombinedDelta(
        title: foundTitle ? title.toString() : '',
        bodyDelta: body,
      );
    } catch (_) {
      return null;
    }
  }

  ChecklistDeltaDecodeResult tryDecodeDocument(Document document) {
    final source = document.toDelta().toJson();
    final decoded = tryDecodeOperations(source);
    if (!decoded.isEligible) return decoded;

    final encoded = encodeBody(decoded.document!);
    final normalizedEncoded = documentFromJsonSafe(encoded).toDelta().toJson();
    final roundTripped = tryDecodeOperations(normalizedEncoded);
    if (!roundTripped.isEligible ||
        !_semanticallyEquivalent(decoded.document!, roundTripped.document!)) {
      return ChecklistDeltaDecodeResult.failure(
        ChecklistDeltaFailureReason.roundTripMismatch,
        'Checklist Delta could not be round-tripped losslessly',
      );
    }
    return decoded;
  }

  ChecklistDeltaDecodeResult tryDecodeCombinedJson(String? content) {
    if (content == null || content.isEmpty) {
      return ChecklistDeltaDecodeResult.failure(
        ChecklistDeltaFailureReason.empty,
        'Checklist content is empty',
      );
    }
    try {
      final decoded = jsonDecode(content);
      if (decoded is! List) {
        return ChecklistDeltaDecodeResult.failure(
          ChecklistDeltaFailureReason.notDelta,
          'Checklist content is not a Delta',
        );
      }
      var bodyStart = 0;
      for (var index = 0; index < decoded.length; index++) {
        final raw = decoded[index];
        if (raw is! Map) continue;
        final attributes = raw['attributes'];
        if (raw['insert'] == '\n' &&
            attributes is Map &&
            attributes[Attribute.header.key] == 1) {
          bodyStart = index + 1;
          break;
        }
      }
      return tryDecodeDocument(
        documentFromJsonSafe(decoded.sublist(bodyStart)),
      );
    } catch (_) {
      return ChecklistDeltaDecodeResult.failure(
        ChecklistDeltaFailureReason.malformed,
        'Malformed checklist Delta',
      );
    }
  }

  ChecklistDeltaDecodeResult tryDecodeOperations(List<dynamic> operations) {
    if (operations.isEmpty) {
      return ChecklistDeltaDecodeResult.failure(
        ChecklistDeltaFailureReason.empty,
        'Checklist is empty',
      );
    }

    final items = <RichChecklistItem>[];
    final inline = Delta();

    try {
      for (final rawOperation in operations) {
        if (rawOperation is! Map) {
          return ChecklistDeltaDecodeResult.failure(
            ChecklistDeltaFailureReason.invalidOperation,
            'Invalid Delta operation',
          );
        }
        final operation = Operation.fromJson(rawOperation);
        if (!operation.isInsert || operation.data is! String) {
          return ChecklistDeltaDecodeResult.failure(
            ChecklistDeltaFailureReason.embed,
            'Checklist contains an embed or non-insert operation',
          );
        }

        final text = operation.data! as String;
        var segmentStart = 0;
        for (var index = 0; index < text.length; index++) {
          if (text.codeUnitAt(index) != 10) continue;

          if (index > segmentStart) {
            final segment = text.substring(segmentStart, index);
            if (_hasBlockAttribute(operation.attributes)) {
              return ChecklistDeltaDecodeResult.failure(
                ChecklistDeltaFailureReason.textBlockAttributes,
                'Checklist text contains block attributes',
              );
            }
            inline.insert(segment, operation.attributes);
          }

          final attributes = Map<String, dynamic>.from(
            operation.attributes ?? const {},
          );
          final list = attributes.remove(Attribute.list.key);
          final indentValue = attributes.remove(Attribute.indent.key);
          if (list != Attribute.checked.value &&
              list != Attribute.unchecked.value) {
            return ChecklistDeltaDecodeResult.failure(
              ChecklistDeltaFailureReason.nonChecklistLine,
              'Every body line must be a checkbox',
            );
          }
          if (_incompatibleBlockKeys.any(attributes.containsKey)) {
            return ChecklistDeltaDecodeResult.failure(
              ChecklistDeltaFailureReason.incompatibleBlock,
              'Checklist contains an incompatible block format',
            );
          }
          final indent = switch (indentValue) {
            null => 0,
            int value when value >= 0 => value,
            num value when value >= 0 => value.toInt(),
            _ => -1,
          };
          if (indent < 0) {
            return ChecklistDeltaDecodeResult.failure(
              ChecklistDeltaFailureReason.invalidIndentation,
              'Checklist contains an invalid indentation level',
            );
          }

          items.add(
            RichChecklistItem(
              id: _newId(),
              inlineDelta: inline.toJson(),
              checked: list == Attribute.checked.value,
              indent: indent,
              lineAttributes: attributes,
            ),
          );
          inline.operations.clear();
          segmentStart = index + 1;
        }

        if (segmentStart < text.length) {
          if (_hasBlockAttribute(operation.attributes)) {
            return ChecklistDeltaDecodeResult.failure(
              ChecklistDeltaFailureReason.textBlockAttributes,
              'Checklist text contains block attributes',
            );
          }
          inline.insert(text.substring(segmentStart), operation.attributes);
        }
      }
    } catch (_) {
      return ChecklistDeltaDecodeResult.failure(
        ChecklistDeltaFailureReason.malformed,
        'Malformed checklist Delta',
      );
    }

    if (inline.isNotEmpty) {
      return ChecklistDeltaDecodeResult.failure(
        ChecklistDeltaFailureReason.unterminatedLine,
        'Checklist does not end with a checkbox newline',
      );
    }
    if (items.isEmpty) {
      return ChecklistDeltaDecodeResult.failure(
        ChecklistDeltaFailureReason.noItems,
        'Checklist has no items',
      );
    }
    if (!_hasValidIndentation(items)) {
      return ChecklistDeltaDecodeResult.failure(
        ChecklistDeltaFailureReason.orphanedIndentation,
        'Checklist contains orphaned indentation',
      );
    }

    return ChecklistDeltaDecodeResult.success(RichChecklistDocument(items));
  }

  ChecklistDeltaDecodeResult tryDecodeEditedRow({
    required RichChecklistItem original,
    required Document document,
  }) {
    final source = document.toDelta().toJson();
    final checklistOperations = <Map<String, dynamic>>[];
    var lineIndex = 0;
    for (final raw in source) {
      final operation = Operation.fromJson(raw);
      if (!operation.isInsert || operation.data is! String) {
        return ChecklistDeltaDecodeResult.failure(
          ChecklistDeltaFailureReason.embed,
          'Checklist item contains an embed',
        );
      }
      final text = operation.data! as String;
      var segmentStart = 0;
      for (var index = 0; index < text.length; index++) {
        if (text.codeUnitAt(index) != 10) continue;
        if (index > segmentStart) {
          checklistOperations.add({
            'insert': text.substring(segmentStart, index),
            if (operation.attributes != null)
              'attributes': Map<String, dynamic>.from(operation.attributes!),
          });
        }
        final attributes = Map<String, dynamic>.from(
          operation.attributes ?? const {},
        );
        attributes[Attribute.list.key] = lineIndex == 0 && original.checked
            ? Attribute.checked.value
            : Attribute.unchecked.value;
        // Decode the isolated row at a temporary root level, then restore the
        // real indentation below. A nested row has no parent inside this
        // single-row document and would otherwise look orphaned to the codec.
        attributes.remove(Attribute.indent.key);
        checklistOperations.add({'insert': '\n', 'attributes': attributes});
        lineIndex++;
        segmentStart = index + 1;
      }
      if (segmentStart < text.length) {
        checklistOperations.add({
          'insert': text.substring(segmentStart),
          if (operation.attributes != null)
            'attributes': Map<String, dynamic>.from(operation.attributes!),
        });
      }
    }

    final decoded = tryDecodeOperations(checklistOperations);
    if (!decoded.isEligible) return decoded;
    final items = [...decoded.document!.items];
    for (var index = 0; index < items.length; index++) {
      items[index] = items[index].copyWith(
        id: index == 0 ? original.id : items[index].id,
        checked: index == 0 ? original.checked : false,
        indent: original.indent,
      );
    }
    return ChecklistDeltaDecodeResult.success(RichChecklistDocument(items));
  }

  List<Map<String, dynamic>> encodeBody(RichChecklistDocument document) {
    return encodeBlock(document, baseIndent: 0);
  }

  List<Map<String, dynamic>> encodeBlock(
    RichChecklistDocument document, {
    required int baseIndent,
  }) {
    final delta = Delta();
    for (final item in document.items) {
      for (final operation in item.delta.toList()) {
        delta.push(operation);
      }
      final attributes = Map<String, dynamic>.from(item.lineAttributes)
        ..[Attribute.list.key] = item.checked
            ? Attribute.checked.value
            : Attribute.unchecked.value;
      final absoluteIndent = item.indent + baseIndent;
      if (absoluteIndent > 0) {
        attributes[Attribute.indent.key] = absoluteIndent;
      } else {
        attributes.remove(Attribute.indent.key);
      }
      delta.insert('\n', attributes);
    }
    return delta.toJson();
  }

  List<Map<String, dynamic>> encodeCombined({
    required String title,
    required RichChecklistDocument document,
  }) => encodeCombinedBody(title: title, bodyDelta: encodeBody(document));

  List<Map<String, dynamic>> encodeCombinedBody({
    required String title,
    required List<Map<String, dynamic>> bodyDelta,
  }) {
    final combined = <Map<String, dynamic>>[];
    if (title.isNotEmpty) {
      combined.add({'insert': title});
      combined.add({
        'insert': '\n',
        'attributes': {'header': 1},
      });
    }
    combined.addAll(_copyOperations(bodyDelta));
    return documentFromJsonSafe(combined).toDelta().toJson();
  }

  String encodeCombinedJson({
    required String title,
    required RichChecklistDocument document,
  }) => jsonEncode(encodeCombined(title: title, document: document));

  String encodeCombinedBodyJson({
    required String title,
    required List<Map<String, dynamic>> bodyDelta,
  }) => jsonEncode(encodeCombinedBody(title: title, bodyDelta: bodyDelta));

  String combinedPlainText({
    required String title,
    required RichChecklistDocument document,
  }) => documentFromJsonSafe(
    encodeCombined(title: title, document: document),
  ).toPlainText().trim();

  String combinedBodyPlainText({
    required String title,
    required List<Map<String, dynamic>> bodyDelta,
  }) => documentFromJsonSafe(
    encodeCombinedBody(title: title, bodyDelta: bodyDelta),
  ).toPlainText().trim();

  int replacementDeltaLength(List<Map<String, dynamic>> operations) =>
      _deltaContentLength(Delta.fromJson(operations));

  String fingerprintOperations(List<Map<String, dynamic>> operations) {
    final canonical = jsonEncode(_canonicalize(operations));
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  String _sectionId(int ordinal, String fingerprint) =>
      'checklist-section-$ordinal-${fingerprint.substring(0, 12)}';

  String? _contextLabelForBlock({
    required List<_ScannedDeltaLine> lines,
    required int startOffset,
    required int endOffset,
  }) {
    for (final line in lines.reversed) {
      if (line.startOffset < startOffset || line.endOffset > endOffset) {
        continue;
      }
      if (line.isChecklist) continue;
      final buffer = StringBuffer();
      var containsEmbed = false;
      for (final operation in line.delta.toList()) {
        final data = operation.data;
        if (data is! String) {
          containsEmbed = true;
          break;
        }
        buffer.write(data.replaceAll('\n', ''));
      }
      if (containsEmbed) continue;
      final label = buffer.toString().trim();
      if (label.isNotEmpty) return label;
    }
    return null;
  }

  List<_ScannedDeltaLine> _scanLines(Delta source) {
    final lines = <_ScannedDeltaLine>[];
    var lineDelta = Delta();
    var lineStart = 0;
    var offset = 0;

    for (final operation in source.toList()) {
      if (!operation.isInsert) continue;
      final data = operation.data;
      if (data is! String) {
        lineDelta.push(operation);
        offset += operation.length ?? 1;
        continue;
      }

      var segmentStart = 0;
      for (var index = 0; index < data.length; index++) {
        if (data.codeUnitAt(index) != 10) continue;
        if (index > segmentStart) {
          final text = data.substring(segmentStart, index);
          lineDelta.insert(text, operation.attributes);
          offset += text.length;
        }
        lineDelta.insert('\n', operation.attributes);
        offset++;
        lines.add(
          _ScannedDeltaLine(
            startOffset: lineStart,
            endOffset: offset,
            delta: lineDelta,
            newlineAttributes: Map<String, dynamic>.from(
              operation.attributes ?? const {},
            ),
          ),
        );
        lineStart = offset;
        lineDelta = Delta();
        segmentStart = index + 1;
      }
      if (segmentStart < data.length) {
        final text = data.substring(segmentStart);
        lineDelta.insert(text, operation.attributes);
        offset += text.length;
      }
    }
    return lines;
  }

  ChecklistBlockLookupResult _decodeScannedBlock(
    List<_ScannedDeltaLine> lines,
  ) {
    final startOffset = lines.first.startOffset;
    final endOffset = lines.last.endOffset;
    final rawBaseIndent = lines.first.newlineAttributes[Attribute.indent.key];
    final baseIndent = switch (rawBaseIndent) {
      null => 0,
      int value when value >= 0 => value,
      num value when value >= 0 => value.toInt(),
      _ => -1,
    };
    if (baseIndent < 0) {
      return ChecklistBlockLookupResult.ineligible(
        startOffset: startOffset,
        endOffset: endOffset,
        failureReason: ChecklistDeltaFailureReason.invalidIndentation,
        reason: 'Checklist contains an invalid indentation level',
      );
    }

    var source = Delta();
    for (final line in lines) {
      source = source.concat(line.delta);
    }
    final normalized = _normalizeBlockIndent(source, baseIndent);
    if (normalized == null) {
      return ChecklistBlockLookupResult.ineligible(
        startOffset: startOffset,
        endOffset: endOffset,
        failureReason: ChecklistDeltaFailureReason.orphanedIndentation,
        reason: 'Checklist indentation falls outside its block',
      );
    }
    final decoded = tryDecodeOperations(normalized.toJson());
    if (!decoded.isEligible) {
      return ChecklistBlockLookupResult.ineligible(
        startOffset: startOffset,
        endOffset: endOffset,
        failureReason:
            decoded.failureReason ?? ChecklistDeltaFailureReason.malformed,
        reason: decoded.reason ?? 'Malformed checklist Delta',
      );
    }

    final encoded = encodeBlock(decoded.document!, baseIndent: baseIndent);
    final normalizedEncoded = _normalizeBlockIndent(
      Delta.fromJson(encoded),
      baseIndent,
    );
    final roundTripped = normalizedEncoded == null
        ? ChecklistDeltaDecodeResult.failure(
            ChecklistDeltaFailureReason.roundTripMismatch,
            'Checklist Delta could not be round-tripped losslessly',
          )
        : tryDecodeOperations(normalizedEncoded.toJson());
    if (!roundTripped.isEligible ||
        !_semanticallyEquivalent(decoded.document!, roundTripped.document!)) {
      return ChecklistBlockLookupResult.ineligible(
        startOffset: startOffset,
        endOffset: endOffset,
        failureReason: ChecklistDeltaFailureReason.roundTripMismatch,
        reason: 'Checklist Delta could not be round-tripped losslessly',
      );
    }

    final sourceDelta = source.toJson();
    return ChecklistBlockLookupResult.eligible(
      ChecklistBlockSlice(
        startOffset: startOffset,
        endOffset: endOffset,
        baseIndent: baseIndent,
        sourceDelta: sourceDelta,
        sourceFingerprint: fingerprintOperations(sourceDelta),
        document: decoded.document!,
      ),
    );
  }

  Delta? _normalizeBlockIndent(Delta source, int baseIndent) {
    final normalized = Delta();
    for (final operation in source.toList()) {
      final data = operation.data;
      if (!operation.isInsert || data is! String) {
        normalized.push(operation);
        continue;
      }
      var segmentStart = 0;
      for (var index = 0; index < data.length; index++) {
        if (data.codeUnitAt(index) != 10) continue;
        if (index > segmentStart) {
          normalized.insert(
            data.substring(segmentStart, index),
            operation.attributes,
          );
        }
        final attributes = Map<String, dynamic>.from(
          operation.attributes ?? const {},
        );
        final rawIndent = attributes[Attribute.indent.key];
        final absoluteIndent = switch (rawIndent) {
          null => 0,
          int value when value >= 0 => value,
          num value when value >= 0 => value.toInt(),
          _ => -1,
        };
        if (absoluteIndent < baseIndent) return null;
        final relativeIndent = absoluteIndent - baseIndent;
        if (relativeIndent == 0) {
          attributes.remove(Attribute.indent.key);
        } else {
          attributes[Attribute.indent.key] = relativeIndent;
        }
        normalized.insert('\n', attributes);
        segmentStart = index + 1;
      }
      if (segmentStart < data.length) {
        normalized.insert(data.substring(segmentStart), operation.attributes);
      }
    }
    return normalized;
  }

  List<Map<String, dynamic>> _spliceBlock({
    required List<Map<String, dynamic>> bodyDelta,
    required ChecklistBlockSlice sourceBlock,
    required List<Map<String, dynamic>> replacementDelta,
  }) {
    final source = Delta.fromJson(bodyDelta);
    final currentSlice = source
        .slice(sourceBlock.startOffset, sourceBlock.endOffset)
        .toJson();
    if (fingerprintOperations(currentSlice) != sourceBlock.sourceFingerprint) {
      throw const ChecklistBlockStaleException();
    }
    return source
        .slice(0, sourceBlock.startOffset)
        .concat(Delta.fromJson(replacementDelta))
        .concat(source.slice(sourceBlock.endOffset))
        .toJson();
  }

  bool _hasBlockAttribute(Map<String, dynamic>? attributes) {
    if (attributes == null) return false;
    return Attribute.blockKeys.any(attributes.containsKey);
  }

  bool _hasValidIndentation(List<RichChecklistItem> items) {
    if (items.first.indent != 0) return false;
    for (var index = 1; index < items.length; index++) {
      if (items[index].indent > items[index - 1].indent + 1) return false;
    }
    return true;
  }
}

bool _semanticallyEquivalent(
  RichChecklistDocument left,
  RichChecklistDocument right,
) {
  if (left.items.length != right.items.length) return false;
  for (var index = 0; index < left.items.length; index++) {
    final leftItem = left.items[index];
    final rightItem = right.items[index];
    if (leftItem.checked != rightItem.checked ||
        leftItem.indent != rightItem.indent ||
        jsonEncode(_canonicalize(leftItem.inlineDelta)) !=
            jsonEncode(_canonicalize(rightItem.inlineDelta)) ||
        jsonEncode(_canonicalize(leftItem.lineAttributes)) !=
            jsonEncode(_canonicalize(rightItem.lineAttributes))) {
      return false;
    }
  }
  return true;
}

class _ScannedDeltaLine {
  const _ScannedDeltaLine({
    required this.startOffset,
    required this.endOffset,
    required this.delta,
    required this.newlineAttributes,
  });

  final int startOffset;
  final int endOffset;
  final Delta delta;
  final Map<String, dynamic> newlineAttributes;

  bool get isChecklist {
    final list = newlineAttributes[Attribute.list.key];
    return list == Attribute.checked.value || list == Attribute.unchecked.value;
  }
}

List<Map<String, dynamic>> _copyOperations(
  List<Map<String, dynamic>> operations,
) => (jsonDecode(jsonEncode(operations)) as List)
    .map((entry) => Map<String, dynamic>.from(entry as Map))
    .toList(growable: false);

int _deltaContentLength(Delta delta) => delta.toList().fold<int>(
  0,
  (length, operation) => length + (operation.length ?? 0),
);

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: _canonicalize(value[key])};
  }
  if (value is List) return value.map(_canonicalize).toList();
  return value;
}
