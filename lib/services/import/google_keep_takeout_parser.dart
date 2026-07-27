import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

class GoogleKeepTakeoutParser {
  const GoogleKeepTakeoutParser();

  KeepParseResult parseZipBytes(
    Uint8List archiveBytes, {
    KeepImportOptions options = const KeepImportOptions(),
    KeepImportCancellationToken? cancellationToken,
  }) {
    if (archiveBytes.length > options.maxArchiveBytes) {
      throw KeepImportValidationException(
        'The ZIP is larger than the ${_formatBytes(options.maxArchiveBytes)} import limit.',
      );
    }

    final archive = ZipDecoder().decodeBytes(archiveBytes, verify: true);
    final entries = <KeepArchiveEntry>[];
    var uncompressedBytes = 0;
    var fileCount = 0;

    for (final file in archive) {
      cancellationToken?.throwIfCancelled();
      if (!file.isFile) continue;
      fileCount++;
      if (fileCount > options.maxFileCount) {
        throw KeepImportValidationException(
          'The ZIP contains more than ${options.maxFileCount} files.',
        );
      }
      if (file.isSymbolicLink) {
        throw const KeepImportValidationException(
          'The ZIP contains symbolic links, which are not supported.',
        );
      }

      final normalized = _safeArchivePath(file.name);
      if (file.size > options.maxEntryBytes) {
        throw KeepImportValidationException(
          '$normalized is larger than the ${_formatBytes(options.maxEntryBytes)} per-file limit.',
        );
      }
      uncompressedBytes += file.size;
      if (uncompressedBytes > options.maxUncompressedBytes) {
        throw KeepImportValidationException(
          'The ZIP expands beyond the ${_formatBytes(options.maxUncompressedBytes)} safety limit.',
        );
      }
      entries.add(KeepArchiveEntry(path: normalized, bytes: file.content));
    }

    return parseEntries(
      entries,
      options: options,
      cancellationToken: cancellationToken,
    );
  }

  KeepParseResult parseEntries(
    List<KeepArchiveEntry> entries, {
    KeepImportOptions options = const KeepImportOptions(),
    KeepImportCancellationToken? cancellationToken,
  }) {
    if (entries.length > options.maxFileCount) {
      throw KeepImportValidationException(
        'The import contains more than ${options.maxFileCount} files.',
      );
    }

    final files = <String, Uint8List>{};
    final pathsByBasename = <String, List<String>>{};
    var totalBytes = 0;
    for (final entry in entries) {
      cancellationToken?.throwIfCancelled();
      final normalized = _safeArchivePath(entry.path);
      if (entry.bytes.length > options.maxEntryBytes) {
        throw KeepImportValidationException(
          '$normalized is larger than the ${_formatBytes(options.maxEntryBytes)} per-file limit.',
        );
      }
      totalBytes += entry.bytes.length;
      if (totalBytes > options.maxUncompressedBytes) {
        throw KeepImportValidationException(
          'The import exceeds the ${_formatBytes(options.maxUncompressedBytes)} safety limit.',
        );
      }
      files[normalized] = entry.bytes;
      pathsByBasename
          .putIfAbsent(path.posix.basename(normalized), () => <String>[])
          .add(normalized);
    }

    final issues = <KeepImportIssue>[];
    final notes = <KeepNoteDraft>[];
    final jsonPaths =
        files.keys
            .where((entryPath) => entryPath.toLowerCase().endsWith('.json'))
            .toList(growable: false)
          ..sort();

    for (final jsonPath in jsonPaths) {
      cancellationToken?.throwIfCancelled();
      try {
        final decoded = jsonDecode(utf8.decode(files[jsonPath]!));
        if (decoded is! Map) {
          issues.add(
            KeepImportIssue(
              kind: KeepImportIssueKind.failure,
              source: jsonPath,
              message: 'Expected a JSON object.',
            ),
          );
          continue;
        }
        final record = Map<String, dynamic>.from(decoded);
        if (!_looksLikeKeepRecord(record)) continue;
        if (!options.includeTrashed && _readBool(record['isTrashed'])) {
          continue;
        }

        final attachmentResult = _resolveAttachments(
          record,
          jsonPath,
          files,
          pathsByBasename,
        );
        issues.addAll(attachmentResult.issues);

        final content = _buildContent(record);
        notes.add(
          KeepNoteDraft(
            sourcePath: jsonPath,
            fingerprint: _fingerprint(record),
            title: _readString(record['title']).trim(),
            plainText: content.plainText,
            delta: content.delta,
            labels: _readLabels(record['labels']),
            color: _readString(record['color']).toUpperCase(),
            pinned: _readBool(record['isPinned']),
            archived: _readBool(record['isArchived']),
            trashed: _readBool(record['isTrashed']),
            createdAt: _timestamp(
              record['createdTimestampUsec'],
              fallback: DateTime.now(),
            ),
            updatedAt: _timestamp(
              record['userEditedTimestampUsec'],
              fallback: _timestamp(
                record['createdTimestampUsec'],
                fallback: DateTime.now(),
              ),
            ),
            attachments: attachmentResult.attachments,
          ),
        );
      } on KeepImportCancelled {
        rethrow;
      } catch (error) {
        issues.add(
          KeepImportIssue(
            kind: KeepImportIssueKind.failure,
            source: jsonPath,
            message: 'Could not parse this record: $error',
          ),
        );
      }
    }

    if (notes.isEmpty && issues.isEmpty) {
      throw const KeepImportValidationException(
        'No Google Keep note records were found in this selection.',
      );
    }

    return KeepParseResult(
      notes: notes,
      issues: issues,
      discovered:
          notes.length +
          issues
              .where((issue) => issue.kind == KeepImportIssueKind.failure)
              .length,
    );
  }

  bool _looksLikeKeepRecord(Map<String, dynamic> record) =>
      record.containsKey('textContent') ||
      record.containsKey('listContent') ||
      record.containsKey('isPinned') ||
      record.containsKey('userEditedTimestampUsec');

  ({List<Map<String, Object?>> delta, String plainText}) _buildContent(
    Map<String, dynamic> record,
  ) {
    final list = record['listContent'];
    if (list is List && list.isNotEmpty) {
      final delta = <Map<String, Object?>>[];
      final plainLines = <String>[];
      for (final value in list) {
        if (value is! Map) continue;
        final item = Map<String, dynamic>.from(value);
        final text = _readString(item['text']);
        final checked = _readBool(item['isChecked']);
        delta
          ..add({'insert': text})
          ..add({
            'insert': '\n',
            'attributes': {'list': checked ? 'checked' : 'unchecked'},
          });
        plainLines.add(text);
      }
      if (delta.isEmpty) delta.add({'insert': '\n'});
      return (delta: delta, plainText: plainLines.join('\n'));
    }

    final text = _readString(record['textContent']);
    return (
      delta: [
        if (text.isNotEmpty) {'insert': text},
        if (!text.endsWith('\n')) {'insert': '\n'},
      ],
      plainText: text,
    );
  }

  _AttachmentResolution _resolveAttachments(
    Map<String, dynamic> record,
    String jsonPath,
    Map<String, Uint8List> files,
    Map<String, List<String>> pathsByBasename,
  ) {
    final attachments = <KeepAttachmentDraft>[];
    final issues = <KeepImportIssue>[];
    final rawAttachments = record['attachments'];
    if (rawAttachments is! List) {
      return _AttachmentResolution(attachments, issues);
    }

    for (final raw in rawAttachments) {
      if (raw is! Map) continue;
      final attachment = Map<String, dynamic>.from(raw);
      final filePath = _readString(attachment['filePath']);
      final mimeType = _readString(attachment['mimetype']).toLowerCase();
      if (filePath.isEmpty) {
        issues.add(
          KeepImportIssue(
            kind: KeepImportIssueKind.warning,
            source: jsonPath,
            message: 'An attachment did not include a file path.',
          ),
        );
        continue;
      }

      final normalizedRelative = _safeRelativeReference(filePath);
      final siblingPath = path.posix.normalize(
        path.posix.join(path.posix.dirname(jsonPath), normalizedRelative),
      );
      String? resolvedPath;
      if (files.containsKey(siblingPath)) {
        resolvedPath = siblingPath;
      } else if (files.containsKey(normalizedRelative)) {
        resolvedPath = normalizedRelative;
      } else {
        final matches =
            pathsByBasename[path.posix.basename(normalizedRelative)];
        if (matches?.length == 1) resolvedPath = matches!.single;
      }

      if (resolvedPath == null) {
        issues.add(
          KeepImportIssue(
            kind: KeepImportIssueKind.warning,
            source: jsonPath,
            message: 'Attachment not found: ${path.posix.basename(filePath)}',
          ),
        );
        continue;
      }

      if (!_isSupportedAttachment(mimeType, resolvedPath)) {
        issues.add(
          KeepImportIssue(
            kind: KeepImportIssueKind.unsupported,
            source: jsonPath,
            message:
                'Unsupported attachment: ${path.posix.basename(resolvedPath)}${mimeType.isEmpty ? '' : ' ($mimeType)'}',
          ),
        );
        continue;
      }
      attachments.add(
        KeepAttachmentDraft(
          archivePath: resolvedPath,
          mimeType: mimeType,
          bytes: files[resolvedPath]!,
        ),
      );
    }

    return _AttachmentResolution(attachments, issues);
  }

  bool _isSupportedAttachment(String mimeType, String filePath) {
    if (mimeType.startsWith('image/') || mimeType.startsWith('audio/')) {
      return true;
    }
    const extensions = {
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.mp3',
      '.wav',
      '.m4a',
      '.ogg',
    };
    return extensions.contains(path.posix.extension(filePath).toLowerCase());
  }

  String _fingerprint(Map<String, dynamic> record) {
    final canonical = jsonEncode(_canonicalize(record));
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: _canonicalize(value[key])};
    }
    if (value is List) {
      return value.map(_canonicalize).toList(growable: false);
    }
    return value;
  }

  List<String> _readLabels(Object? raw) {
    if (raw is! List) return const [];
    final names = <String>{};
    for (final value in raw) {
      if (value is Map) {
        final name = _readString(value['name']).trim();
        if (name.isNotEmpty && !name.contains(',')) names.add(name);
      }
    }
    return names.toList(growable: false);
  }

  DateTime _timestamp(Object? raw, {required DateTime fallback}) {
    final microseconds = int.tryParse(_readString(raw));
    if (microseconds == null || microseconds <= 0) return fallback;
    return DateTime.fromMicrosecondsSinceEpoch(
      microseconds,
      isUtc: true,
    ).toLocal();
  }

  bool _readBool(Object? value) =>
      value == true || value == 1 || value?.toString().toLowerCase() == 'true';

  String _readString(Object? value) => value?.toString() ?? '';

  String _safeArchivePath(String value) {
    final normalized = path.posix.normalize(value.replaceAll('\\', '/'));
    if (normalized.isEmpty ||
        normalized == '.' ||
        normalized.startsWith('/') ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw KeepImportValidationException('Unsafe archive path: $value');
    }
    return normalized;
  }

  String _safeRelativeReference(String value) {
    final normalized = _safeArchivePath(value);
    if (normalized.split('/').contains('..')) {
      throw KeepImportValidationException('Unsafe attachment path: $value');
    }
    return normalized;
  }

  String _formatBytes(int bytes) {
    final mebibytes = bytes / KeepImportOptions.mebibyte;
    return '${mebibytes.toStringAsFixed(mebibytes.roundToDouble() == mebibytes ? 0 : 1)} MB';
  }
}

class _AttachmentResolution {
  final List<KeepAttachmentDraft> attachments;
  final List<KeepImportIssue> issues;

  const _AttachmentResolution(this.attachments, this.issues);
}
