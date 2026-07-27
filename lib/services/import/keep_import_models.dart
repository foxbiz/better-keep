import 'dart:convert';

import 'package:flutter/foundation.dart';

enum ImportSource { googleKeepTakeout }

enum KeepImportPhase {
  validating,
  parsing,
  preparingAttachments,
  saving,
  complete,
}

enum KeepImportIssueKind { warning, failure, unsupported }

@immutable
class KeepImportOptions {
  static const int mebibyte = 1024 * 1024;

  final bool includeTrashed;
  final bool skipDuplicates;
  final int maxArchiveBytes;
  final int maxUncompressedBytes;
  final int maxEntryBytes;
  final int maxFileCount;

  const KeepImportOptions({
    this.includeTrashed = true,
    this.skipDuplicates = true,
    this.maxArchiveBytes = 100 * mebibyte,
    this.maxUncompressedBytes = 500 * mebibyte,
    this.maxEntryBytes = 50 * mebibyte,
    this.maxFileCount = 20000,
  });
}

@immutable
class KeepImportProgress {
  final KeepImportPhase phase;
  final int completed;
  final int total;
  final String message;

  const KeepImportProgress({
    required this.phase,
    required this.completed,
    required this.total,
    required this.message,
  });

  double? get fraction => total <= 0 ? null : completed / total;
}

@immutable
class KeepImportIssue {
  final KeepImportIssueKind kind;
  final String source;
  final String message;

  const KeepImportIssue({
    required this.kind,
    required this.source,
    required this.message,
  });

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'source': source,
    'message': message,
  };
}

@immutable
class KeepImportReport {
  final ImportSource source;
  final DateTime startedAt;
  final DateTime completedAt;
  final int discovered;
  final int imported;
  final int skipped;
  final int failed;
  final int warnings;
  final int unsupported;
  final List<KeepImportIssue> issues;

  const KeepImportReport({
    required this.source,
    required this.startedAt,
    required this.completedAt,
    required this.discovered,
    required this.imported,
    required this.skipped,
    required this.failed,
    required this.warnings,
    required this.unsupported,
    required this.issues,
  });

  Map<String, Object?> toJson() => {
    'source': source.name,
    'startedAt': startedAt.toIso8601String(),
    'completedAt': completedAt.toIso8601String(),
    'discovered': discovered,
    'imported': imported,
    'skipped': skipped,
    'failed': failed,
    'warnings': warnings,
    'unsupported': unsupported,
    'issues': issues.map((issue) => issue.toJson()).toList(growable: false),
  };

  String toShareText() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class KeepImportCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void throwIfCancelled() {
    if (_cancelled) throw const KeepImportCancelled();
  }
}

class KeepImportCancelled implements Exception {
  const KeepImportCancelled();

  @override
  String toString() => 'Google Keep import was cancelled';
}

class KeepImportValidationException implements Exception {
  final String message;

  const KeepImportValidationException(this.message);

  @override
  String toString() => message;
}

@immutable
class KeepArchiveEntry {
  final String path;
  final Uint8List bytes;

  const KeepArchiveEntry({required this.path, required this.bytes});
}

@immutable
class KeepAttachmentDraft {
  final String archivePath;
  final String mimeType;
  final Uint8List bytes;

  const KeepAttachmentDraft({
    required this.archivePath,
    required this.mimeType,
    required this.bytes,
  });
}

@immutable
class KeepNoteDraft {
  final String sourcePath;
  final String fingerprint;
  final String title;
  final String plainText;
  final List<Map<String, Object?>> delta;
  final List<String> labels;
  final String color;
  final bool pinned;
  final bool archived;
  final bool trashed;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<KeepAttachmentDraft> attachments;

  const KeepNoteDraft({
    required this.sourcePath,
    required this.fingerprint,
    required this.title,
    required this.plainText,
    required this.delta,
    required this.labels,
    required this.color,
    required this.pinned,
    required this.archived,
    required this.trashed,
    required this.createdAt,
    required this.updatedAt,
    required this.attachments,
  });
}

@immutable
class KeepParseResult {
  final List<KeepNoteDraft> notes;
  final List<KeepImportIssue> issues;
  final int discovered;

  const KeepParseResult({
    required this.notes,
    required this.issues,
    required this.discovered,
  });
}
