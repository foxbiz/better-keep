import 'dart:async';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

/// Disposable plaintext files made available to one platform share operation.
class ShareAttachmentLease {
  final List<XFile> files;
  final List<String> _paths;
  final FileSystem _fileSystem;
  Future<void>? _releaseFuture;

  ShareAttachmentLease._(this.files, this._paths, this._fileSystem);

  Future<void> release() => _releaseFuture ??= _release();

  Future<void> _release() async {
    for (final filePath in _paths.reversed) {
      try {
        await _fileSystem.delete(filePath);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to remove a temporary share attachment',
          error,
          stackTrace,
        );
      }
    }
  }
}

class _ShareAttachmentCandidate {
  final String source;
  final String fileName;
  final String mimeType;

  const _ShareAttachmentCandidate({
    required this.source,
    required this.fileName,
    required this.mimeType,
  });
}

/// Stages authenticated attachment bytes for the lifetime of one share sheet.
///
/// The canonical attachment is never modified and the staged path is never
/// persisted. Each invocation uses an isolated directory so concurrent shares
/// cannot overwrite or delete one another's files.
class ShareAttachmentStagingService {
  static const cacheDirectoryName = 'share_attachments';

  final FileSystem storage;
  final String Function() newId;

  ShareAttachmentStagingService({
    required FileSystem fileSystem,
    String Function()? newId,
  }) : storage = fileSystem,
       newId = newId ?? const Uuid().v4;

  static Future<ShareAttachmentStagingService> platform() async =>
      ShareAttachmentStagingService(fileSystem: await fileSystem());

  Future<ShareAttachmentLease> stage(Note note) async {
    final candidates = _collectCandidates(note);
    if (candidates.isEmpty) {
      return ShareAttachmentLease._(const [], const [], storage);
    }

    final root = path.join(await storage.cacheDir, cacheDirectoryName);
    final shareDirectory = path.join(root, newId());
    await storage.createDirectory(shareDirectory);

    final files = <XFile>[];
    final stagedPaths = <String>[];
    final usedNames = <String>{};
    try {
      for (final candidate in candidates) {
        final fileName = _uniqueSafeName(candidate.fileName, usedNames);
        final destination = path.join(shareDirectory, fileName);
        try {
          final bytes = await note.readAttachmentForSession(candidate.source);
          if (bytes.isEmpty) throw StateError('Attachment is empty');
          // Record ownership before writing so a partial write is still removed
          // by the lease or by the outer failure cleanup.
          stagedPaths.add(destination);
          await storage.writeBytes(destination, bytes);
          final verified = await storage.readBytes(destination);
          if (!listEquals(verified, bytes)) {
            throw StateError('Temporary share attachment failed verification');
          }
          files.add(XFile(destination, mimeType: candidate.mimeType));
        } catch (error, stackTrace) {
          AppLogger.error(
            note.locked
                ? 'Failed to stage a protected share attachment'
                : 'Failed to stage a share attachment',
            error,
            stackTrace,
          );
        }
      }
      return ShareAttachmentLease._(files, stagedPaths, storage);
    } catch (_) {
      await ShareAttachmentLease._(const [], stagedPaths, storage).release();
      rethrow;
    }
  }

  /// Removes plaintext files left by a terminated share operation.
  ///
  /// Empty platform directories are harmless; only file entries can contain
  /// attachment data. Traversal is restricted to the dedicated cache root.
  Future<int> cleanupStaleFiles() async {
    final root = path.join(await storage.cacheDir, cacheDirectoryName);
    var deleted = 0;
    for (final entry in await storage.list(root)) {
      deleted += await _deleteEntryFiles(entry);
    }
    return deleted;
  }

  Future<int> _deleteEntryFiles(String entry) async {
    try {
      if (await storage.isFile(entry)) {
        return await storage.delete(entry) ? 1 : 0;
      }
      if (!await storage.isDirectory(entry)) return 0;
      var deleted = 0;
      for (final child in await storage.list(entry)) {
        deleted += await _deleteEntryFiles(child);
      }
      return deleted;
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to remove a stale share attachment',
        error,
        stackTrace,
      );
      return 0;
    }
  }

  static List<_ShareAttachmentCandidate> _collectCandidates(Note note) {
    final candidates = <_ShareAttachmentCandidate>[];
    final seenSources = <String>{};
    var imageIndex = 0;
    var sketchIndex = 0;
    var audioIndex = 0;

    for (final attachment in note.attachments) {
      late final String? source;
      late final String fileName;
      late final String mimeType;
      switch (attachment.type) {
        case AttachmentType.image:
          source = attachment.image?.src;
          final extension = _safeSourceExtension(source, 'jpg');
          mimeType = switch (extension) {
            'png' => 'image/png',
            'gif' => 'image/gif',
            'webp' => 'image/webp',
            _ => 'image/jpeg',
          };
          fileName = 'image_${imageIndex++}.$extension';
        case AttachmentType.sketch:
          if (attachment.sketch?.requiresLegacyMigration ?? false) continue;
          source = attachment.sketch?.previewImage;
          mimeType = 'image/png';
          fileName = 'sketch_${sketchIndex++}.png';
        case AttachmentType.audio:
          source = attachment.recording?.src;
          final extension = _safeSourceExtension(source, 'm4a');
          mimeType = switch (extension) {
            'mp3' => 'audio/mpeg',
            'wav' => 'audio/wav',
            'aac' => 'audio/aac',
            'ogg' => 'audio/ogg',
            _ => 'audio/mp4',
          };
          final title = attachment.recording?.title;
          fileName = title != null && title.trim().isNotEmpty
              ? (path.extension(title).isEmpty ? '$title.$extension' : title)
              : 'audio_${audioIndex++}.$extension';
      }
      if (source == null || source.isEmpty || !seenSources.add(source)) {
        continue;
      }
      candidates.add(
        _ShareAttachmentCandidate(
          source: source,
          fileName: fileName,
          mimeType: mimeType,
        ),
      );
    }
    return candidates;
  }

  static String _safeSourceExtension(String? source, String fallback) {
    if (source == null || source.isEmpty) return fallback;
    if (source.startsWith('data:')) {
      final match = RegExp(r'^data:[^/]+/([a-zA-Z0-9+.-]+)').firstMatch(source);
      final value = match?.group(1)?.toLowerCase();
      if (value != null && value.length <= 10) return value;
      return fallback;
    }
    final value = path.extension(Uri.tryParse(source)?.path ?? source);
    if (value.length <= 1 || value.length > 11) return fallback;
    return value.substring(1).toLowerCase();
  }

  static String _uniqueSafeName(String requested, Set<String> usedNames) {
    var safe = path
        .basename(requested)
        .replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_');
    safe = safe.replaceAll(RegExp(r'^\.+'), '');
    if (safe.trim().isEmpty) safe = 'attachment';
    final extension = path.extension(safe);
    final stem = path.basenameWithoutExtension(safe);
    var candidate = safe;
    var suffix = 2;
    while (!usedNames.add(candidate.toLowerCase())) {
      candidate = '${stem}_$suffix$extension';
      suffix++;
    }
    return candidate;
  }
}
