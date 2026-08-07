import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

class GoogleKeepTakeoutParser {
  const GoogleKeepTakeoutParser({this.yieldControl});

  final Future<void> Function()? yieldControl;

  Future<KeepParseResult> parseZipBytes(
    Uint8List archiveBytes, {
    KeepImportOptions options = const KeepImportOptions(),
    KeepImportCancellationToken? cancellationToken,
  }) async {
    if (archiveBytes.length > options.maxArchiveBytes) {
      throw KeepImportValidationException(
        'The ZIP is larger than the ${_formatBytes(options.maxArchiveBytes)} import limit.',
      );
    }

    cancellationToken?.throwIfCancelled();
    final archive = ZipDecoder().decodeBytes(archiveBytes);
    final entries = <_ParserEntry>[];
    try {
      for (final file in archive) {
        cancellationToken?.throwIfCancelled();
        if (!file.isFile) continue;
        if (file.isSymbolicLink) {
          throw const KeepImportValidationException(
            'The ZIP contains symbolic links, which are not supported.',
          );
        }
        entries.add(
          _ArchiveParserEntry(
            path: _safeArchivePath(file.name),
            file: file,
            maxReadBytes: options.maxEntryBytes,
          ),
        );
      }
      return await _parse(
        entries,
        options: options,
        cancellationToken: cancellationToken,
      );
    } catch (_) {
      await Future.wait(entries.map((entry) => entry.forceClose()));
      rethrow;
    }
  }

  Future<KeepParseResult> parseEntries(
    List<KeepArchiveEntry> entries, {
    KeepImportOptions options = const KeepImportOptions(),
    KeepImportCancellationToken? cancellationToken,
  }) async {
    final parserEntries = entries
        .map(
          (entry) => _MemoryParserEntry(
            path: _safeArchivePath(entry.path),
            bytes: entry.bytes,
          ),
        )
        .toList(growable: false);
    return _parse(
      parserEntries,
      options: options,
      cancellationToken: cancellationToken,
    );
  }

  Future<KeepParseResult> _parse(
    List<_ParserEntry> entries, {
    required KeepImportOptions options,
    KeepImportCancellationToken? cancellationToken,
  }) async {
    if (entries.length > options.maxFileCount) {
      await Future.wait(entries.map((entry) => entry.forceClose()));
      throw KeepImportValidationException(
        'The import contains more than ${options.maxFileCount} files.',
      );
    }

    final files = <String, _ParserEntry>{};
    final pathsByBasename = <String, List<String>>{};
    var totalBytes = 0;
    final notes = <KeepNoteDraft>[];
    try {
      for (final entry in entries) {
        cancellationToken?.throwIfCancelled();
        if (entry.size > options.maxEntryBytes) {
          throw KeepImportValidationException(
            '${entry.path} is larger than the ${_formatBytes(options.maxEntryBytes)} per-file limit.',
          );
        }
        totalBytes += entry.size;
        if (totalBytes > options.maxUncompressedBytes) {
          throw KeepImportValidationException(
            'The import exceeds the ${_formatBytes(options.maxUncompressedBytes)} safety limit.',
          );
        }
        if (files.containsKey(entry.path)) {
          throw KeepImportValidationException(
            'The ZIP contains a duplicate path: ${entry.path}',
          );
        }
        files[entry.path] = entry;
        pathsByBasename
            .putIfAbsent(path.posix.basename(entry.path), () => <String>[])
            .add(entry.path);
      }

      final issues = <KeepImportIssue>[];
      final jsonPaths =
          files.keys
              .where((entryPath) => entryPath.toLowerCase().endsWith('.json'))
              .toList(growable: false)
            ..sort();

      for (final jsonPath in jsonPaths) {
        await _yield();
        cancellationToken?.throwIfCancelled();
        _AttachmentResolution? attachmentResult;
        var transferredAttachments = false;
        try {
          final jsonBytes = await files[jsonPath]!.read(cancellationToken);
          cancellationToken?.throwIfCancelled();
          final decoded = jsonDecode(utf8.decode(jsonBytes));
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

          attachmentResult = await _resolveAttachments(
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
          transferredAttachments = true;
        } on KeepImportCancelled {
          rethrow;
        } on KeepImportValidationException {
          rethrow;
        } catch (error) {
          issues.add(
            KeepImportIssue(
              kind: KeepImportIssueKind.failure,
              source: jsonPath,
              message: 'Could not parse this record: $error',
            ),
          );
        } finally {
          if (!transferredAttachments && attachmentResult != null) {
            await attachmentResult.dispose();
          }
        }
      }

      if (notes.isEmpty && issues.isEmpty) {
        throw const KeepImportValidationException(
          'No Google Keep note records were found in this selection.',
        );
      }

      await Future.wait(entries.map((entry) => entry.finishParsing()));
      return KeepParseResult(
        notes: notes,
        issues: issues,
        discovered:
            notes.length +
            issues
                .where((issue) => issue.kind == KeepImportIssueKind.failure)
                .length,
      );
    } catch (_) {
      await Future.wait(notes.map((note) => note.dispose()));
      await Future.wait(entries.map((entry) => entry.forceClose()));
      rethrow;
    }
  }

  Future<void> _yield() =>
      yieldControl?.call() ?? Future<void>.delayed(Duration.zero);

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

  Future<_AttachmentResolution> _resolveAttachments(
    Map<String, dynamic> record,
    String jsonPath,
    Map<String, _ParserEntry> files,
    Map<String, List<String>> pathsByBasename,
  ) async {
    final attachments = <KeepAttachmentDraft>[];
    final issues = <KeepImportIssue>[];
    try {
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
            source: files[resolvedPath]!.createSource(),
          ),
        );
      }

      return _AttachmentResolution(attachments, issues);
    } catch (_) {
      await Future.wait(
        attachments.map((attachment) => attachment.source.dispose()),
      );
      rethrow;
    }
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

  static String _safeArchivePath(String value) {
    final portable = value.replaceAll('\\', '/');
    final segments = portable.split('/');
    final normalized = path.posix.normalize(portable);
    if (normalized.isEmpty ||
        normalized == '.' ||
        normalized.startsWith('/') ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        segments.contains('..') ||
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

  static String _formatBytes(int bytes) {
    final mebibytes = bytes / KeepImportOptions.mebibyte;
    return '${mebibytes.toStringAsFixed(mebibytes.roundToDouble() == mebibytes ? 0 : 1)} MB';
  }
}

abstract class _ParserEntry {
  _ParserEntry({required this.path, required this.size});

  final String path;
  final int size;
  var _references = 0;
  var _parsingFinished = false;
  var _closed = false;

  Future<Uint8List> load();

  Future<void> closeContent();

  Future<Uint8List> read(KeepImportCancellationToken? token) async {
    if (_closed) throw StateError('Archive entry $path has been released.');
    token?.throwIfCancelled();
    final bytes = await load();
    token?.throwIfCancelled();
    return bytes;
  }

  KeepAttachmentSource createSource() {
    if (_closed) throw StateError('Archive entry $path has been released.');
    _references++;
    return _ParserAttachmentSource(this);
  }

  Future<void> releaseSource() async {
    if (_references > 0) _references--;
    if (_parsingFinished && _references == 0) await _close();
  }

  Future<void> finishParsing() async {
    _parsingFinished = true;
    if (_references == 0) await _close();
  }

  Future<void> forceClose() => _close();

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await closeContent();
  }
}

class _MemoryParserEntry extends _ParserEntry {
  _MemoryParserEntry({required super.path, required Uint8List bytes})
    : _bytes = bytes,
      super(size: bytes.length);

  Uint8List? _bytes;

  @override
  Future<Uint8List> load() async => _bytes!;

  @override
  Future<void> closeContent() async {
    _bytes = null;
  }
}

class _ArchiveParserEntry extends _ParserEntry {
  _ArchiveParserEntry({
    required super.path,
    required this.file,
    required this.maxReadBytes,
  }) : super(size: file.size);

  final ArchiveFile file;
  final int maxReadBytes;

  @override
  Future<Uint8List> load() async {
    final output = _BoundedOutputMemoryStream(maxBytes: maxReadBytes);
    file.writeContent(output, freeMemory: true);
    final bytes = output.getBytes();
    if (bytes.length != size) {
      throw KeepImportValidationException(
        '${this.path} expanded to ${bytes.length} bytes, but the ZIP declared $size bytes.',
      );
    }
    final declaredCrc32 = file.crc32;
    if (declaredCrc32 != null && getCrc32(bytes) != declaredCrc32) {
      throw KeepImportValidationException(
        '${this.path} failed its ZIP checksum validation.',
      );
    }
    return bytes;
  }

  @override
  Future<void> closeContent() => file.close();
}

class _ParserAttachmentSource implements KeepAttachmentSource {
  _ParserAttachmentSource(this.entry);

  final _ParserEntry entry;
  var _disposed = false;

  @override
  int get byteLength => entry.size;

  @override
  Future<Uint8List> read({KeepImportCancellationToken? cancellationToken}) {
    if (_disposed) {
      throw StateError('Attachment source ${entry.path} has been released.');
    }
    return entry.read(cancellationToken);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await entry.releaseSource();
  }
}

class _BoundedOutputMemoryStream extends OutputMemoryStream {
  _BoundedOutputMemoryStream({required this.maxBytes})
    : super(size: maxBytes.clamp(1, OutputMemoryStream.defaultBufferSize));

  final int maxBytes;

  void _ensureCapacity(int additionalBytes) {
    if (length + additionalBytes > maxBytes) {
      throw KeepImportValidationException(
        'An archive entry expands beyond the ${GoogleKeepTakeoutParser._formatBytes(maxBytes)} per-file limit.',
      );
    }
  }

  @override
  void writeByte(int value) {
    _ensureCapacity(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _ensureCapacity(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _ensureCapacity(stream.length);
    super.writeStream(stream);
  }
}

class _AttachmentResolution {
  const _AttachmentResolution(this.attachments, this.issues);

  final List<KeepAttachmentDraft> attachments;
  final List<KeepImportIssue> issues;

  Future<void> dispose() =>
      Future.wait(attachments.map((attachment) => attachment.source.dispose()));
}
