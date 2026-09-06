import 'dart:async';
import 'dart:convert';

import 'package:better_keep/models/base_model.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/image_attachment_preparation_service.dart';
import 'package:better_keep/services/import/google_keep_takeout_parser.dart';
import 'package:better_keep/services/import/import_fingerprint_store.dart';
import 'package:better_keep/services/import/keep_archive_input.dart';
import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:better_keep/services/label_sync_service.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

typedef KeepImportProgressCallback = void Function(KeepImportProgress progress);

abstract interface class KeepImportPersistence {
  Future<Set<String>> existingFingerprints(ImportSource source);

  Future<KeepPersistenceResult> commit(
    List<KeepNoteDraft> drafts, {
    required ImportSource source,
    required KeepImportCancellationToken cancellationToken,
    KeepImportProgressCallback? onProgress,
  });
}

@immutable
class KeepPersistenceResult {
  final int imported;
  final List<KeepImportIssue> issues;

  const KeepPersistenceResult({required this.imported, this.issues = const []});
}

class GoogleKeepImportService {
  final GoogleKeepTakeoutParser parser;
  final KeepImportPersistence persistence;

  GoogleKeepImportService({
    GoogleKeepTakeoutParser? parser,
    KeepImportPersistence? persistence,
  }) : parser = parser ?? const GoogleKeepTakeoutParser(),
       persistence = persistence ?? DatabaseKeepImportPersistence();

  Future<KeepImportReport> importZip(
    KeepArchiveInput input, {
    KeepImportOptions options = const KeepImportOptions(),
    KeepImportCancellationToken? cancellationToken,
    KeepImportProgressCallback? onProgress,
  }) async {
    final token = cancellationToken ?? KeepImportCancellationToken();
    onProgress?.call(
      const KeepImportProgress(
        phase: KeepImportPhase.validating,
        completed: 0,
        total: 1,
        message: 'Validating Google Takeout archive…',
      ),
    );
    token.throwIfCancelled();
    input.validateSize(options.maxArchiveBytes);
    final archiveBytes = await input.read(
      maxBytes: options.maxArchiveBytes,
      cancellationToken: token,
    );
    final parsed = await parser.parseZipBytes(
      archiveBytes,
      options: options,
      cancellationToken: token,
    );
    try {
      return await _importParsed(
        parsed,
        options: options,
        cancellationToken: token,
        onProgress: onProgress,
      );
    } finally {
      await parsed.dispose();
    }
  }

  Future<KeepImportReport> _importParsed(
    KeepParseResult parsed, {
    required KeepImportOptions options,
    required KeepImportCancellationToken cancellationToken,
    KeepImportProgressCallback? onProgress,
  }) async {
    final startedAt = DateTime.now();
    cancellationToken.throwIfCancelled();
    onProgress?.call(
      KeepImportProgress(
        phase: KeepImportPhase.parsing,
        completed: parsed.notes.length,
        total: parsed.discovered,
        message: 'Checking for notes already imported…',
      ),
    );

    final existing = options.skipDuplicates
        ? await persistence.existingFingerprints(ImportSource.googleKeepTakeout)
        : <String>{};
    final seen = <String>{};
    final pending = <KeepNoteDraft>[];
    var skipped = 0;
    for (final draft in parsed.notes) {
      cancellationToken.throwIfCancelled();
      if (_isEmptyDraft(draft)) {
        skipped++;
        await draft.dispose();
        continue;
      }
      if (options.skipDuplicates &&
          (existing.contains(draft.fingerprint) ||
              !seen.add(draft.fingerprint))) {
        skipped++;
        await draft.dispose();
      } else {
        seen.add(draft.fingerprint);
        pending.add(draft);
      }
    }

    final persistenceResult = pending.isEmpty
        ? const KeepPersistenceResult(imported: 0)
        : await persistence.commit(
            pending,
            source: ImportSource.googleKeepTakeout,
            cancellationToken: cancellationToken,
            onProgress: onProgress,
          );

    final issues = [...parsed.issues, ...persistenceResult.issues];
    final report = KeepImportReport(
      source: ImportSource.googleKeepTakeout,
      startedAt: startedAt,
      completedAt: DateTime.now(),
      discovered: parsed.discovered,
      imported: persistenceResult.imported,
      skipped: skipped,
      failed: issues
          .where((issue) => issue.kind == KeepImportIssueKind.failure)
          .length,
      warnings: issues
          .where((issue) => issue.kind == KeepImportIssueKind.warning)
          .length,
      unsupported: issues
          .where((issue) => issue.kind == KeepImportIssueKind.unsupported)
          .length,
      issues: List.unmodifiable(issues),
    );
    onProgress?.call(
      KeepImportProgress(
        phase: KeepImportPhase.complete,
        completed: report.imported,
        total: pending.length,
        message: 'Google Keep import complete.',
      ),
    );
    return report;
  }

  bool _isEmptyDraft(KeepNoteDraft draft) =>
      draft.title.isEmpty &&
      draft.plainText.isEmpty &&
      draft.attachments.isEmpty;
}

class DatabaseKeepImportPersistence implements KeepImportPersistence {
  final ImageAttachmentPreparationService imagePreparation;
  final DateTime Function() now;
  final String Function() newId;

  DatabaseKeepImportPersistence({
    ImageAttachmentPreparationService? imagePreparation,
    DateTime Function()? now,
    String Function()? newId,
  }) : imagePreparation =
           imagePreparation ?? ImageAttachmentPreparationService.platform(),
       now = now ?? DateTime.now,
       newId = newId ?? (() => const Uuid().v4());

  @override
  Future<Set<String>> existingFingerprints(ImportSource source) =>
      AppState.db.transaction((transaction) async {
        await transaction.delete(
          ImportFingerprintStore.table,
          where:
              '''
            source = ?
            AND NOT EXISTS (
              SELECT 1 FROM ${Note.model}
              WHERE ${Note.model}.id = ${ImportFingerprintStore.table}.note_id
            )
          ''',
          whereArgs: [source.name],
        );
        return ImportFingerprintStore.getForSource(transaction, source.name);
      });

  @override
  Future<KeepPersistenceResult> commit(
    List<KeepNoteDraft> drafts, {
    required ImportSource source,
    required KeepImportCancellationToken cancellationToken,
    KeepImportProgressCallback? onProgress,
  }) async {
    if (drafts.isEmpty) {
      return const KeepPersistenceResult(imported: 0);
    }

    final issues = <KeepImportIssue>[];
    final prepared = <_PreparedKeepNote>[];
    final leases = <UncommittedAttachmentSourceLease>[];
    final currentLabels = await Label.get();
    final labelsByName = {
      for (final label in currentLabels) label.name.toLowerCase(): label,
    };
    final createdLabels = <Label>[];
    final maxRow = await AppState.db.rawQuery(
      'SELECT MAX(id) AS max_id FROM ${Note.model}',
    );
    final existingMax = maxRow.first['max_id'] as int? ?? 0;
    var nextNoteId = now().millisecondsSinceEpoch;
    if (nextNoteId <= existingMax) nextNoteId = existingMax + 1;

    try {
      for (var draftIndex = 0; draftIndex < drafts.length; draftIndex++) {
        cancellationToken.throwIfCancelled();
        final draft = drafts[draftIndex];
        onProgress?.call(
          KeepImportProgress(
            phase: KeepImportPhase.preparingAttachments,
            completed: draftIndex,
            total: drafts.length,
            message:
                'Preparing “${draft.title.isEmpty ? 'Untitled' : draft.title}”…',
          ),
        );

        final noteAttachments = <NoteAttachment>[];
        var imageIndex = 0;
        for (final attachment in draft.attachments) {
          cancellationToken.throwIfCancelled();
          try {
            final sourceBytes = await attachment.source.read(
              cancellationToken: cancellationToken,
            );
            cancellationToken.throwIfCancelled();
            if (_isImage(attachment)) {
              final preparedImage = await imagePreparation.prepare(
                sourceBytes: sourceBytes,
                extension: path.extension(attachment.archivePath),
                generateBlurredThumbnail: true,
              );
              leases.add(preparedImage.sourceLease);
              noteAttachments.add(
                NoteAttachment.image(
                  NoteImage(
                    src: preparedImage.path,
                    size: preparedImage.byteLength,
                    index: imageIndex++,
                    aspectRatio:
                        '${preparedImage.dimensions.width}:${preparedImage.dimensions.height}',
                    lastModified: draft.updatedAt.toIso8601String(),
                    blurredThumbnail: preparedImage.blurredThumbnail,
                  ),
                ),
              );
            } else {
              final fs = await fileSystem();
              final extension = _safeExtension(attachment.archivePath);
              final outputPath = path.join(
                await fs.documentDir,
                '${newId()}$extension',
              );
              final lease = UncommittedAttachmentSourceLease(
                sourcePath: outputPath,
                cleanupSource: (sourcePath) async {
                  await (await fileSystem()).delete(sourcePath);
                },
              );
              try {
                await writeEncryptedBytes(outputPath, sourceBytes);
                leases.add(lease);
                noteAttachments.add(
                  NoteAttachment.audio(
                    NoteRecording(
                      src: outputPath,
                      title: path.basename(attachment.archivePath),
                    ),
                  ),
                );
              } catch (_) {
                await lease.releaseByCaller();
                rethrow;
              }
            }
          } catch (error, stackTrace) {
            AppLogger.error(
              'Could not prepare imported attachment ${attachment.archivePath}',
              error,
              stackTrace,
            );
            issues.add(
              KeepImportIssue(
                kind: KeepImportIssueKind.warning,
                source: draft.sourcePath,
                message:
                    'Could not import attachment ${path.basename(attachment.archivePath)}.',
              ),
            );
          } finally {
            await attachment.source.dispose();
          }
        }

        final normalizedLabels = <String>[];
        for (final labelName in draft.labels) {
          final key = labelName.toLowerCase();
          var label = labelsByName[key];
          if (label == null) {
            final timestamp = now();
            label = Label(
              name: labelName,
              syncId: newId(),
              createdAt: timestamp,
              updatedAt: timestamp,
            );
            labelsByName[key] = label;
            createdLabels.add(label);
          }
          normalizedLabels.add(label.name);
        }

        final note = Note(
          id: nextNoteId++,
          syncId: newId(),
          title: draft.title,
          labels: normalizedLabels.join(','),
          content: _encodeContent(draft),
          plainText: draft.plainText,
          pinned: draft.pinned,
          archived: draft.archived,
          trashed: draft.trashed,
          color: _mapColor(draft.color),
          createdAt: draft.createdAt,
          updatedAt: draft.updatedAt,
          attachments: noteAttachments,
        );
        prepared.add(
          _PreparedKeepNote(
            note: note,
            fingerprint: draft.fingerprint,
            row: await note.toJsonAsync(),
          ),
        );
      }

      cancellationToken.throwIfCancelled();
      onProgress?.call(
        KeepImportProgress(
          phase: KeepImportPhase.saving,
          completed: 0,
          total: prepared.length,
          message: 'Saving imported notes atomically…',
        ),
      );

      await AppState.db.transaction((transaction) async {
        for (final label in createdLabels) {
          cancellationToken.throwIfCancelled();
          final labelId = await transaction.insert(
            Label.model,
            label.toJson(),
            conflictAlgorithm: ConflictAlgorithm.abort,
          );
          label.id = labelId;
          await transaction.insert('label_sync_track', {
            'local_id': labelId,
            'action': 'upload',
            'status': 'pending',
            'created_at': label.createdAt!.toIso8601String(),
            'updated_at': label.updatedAt!.toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.abort);
        }

        for (var index = 0; index < prepared.length; index++) {
          cancellationToken.throwIfCancelled();
          final item = prepared[index];
          await transaction.insert(
            Note.model,
            item.row,
            conflictAlgorithm: ConflictAlgorithm.abort,
          );
          final timestamp = now().toIso8601String();
          await transaction.insert('sync_track', {
            'local_id': item.note.id,
            'action': 'upload',
            'status': 'pending',
            'created_at': timestamp,
            'updated_at': timestamp,
          }, conflictAlgorithm: ConflictAlgorithm.abort);
          await transaction.insert(ImportFingerprintStore.table, {
            'fingerprint': item.fingerprint,
            'source': source.name,
            'note_id': item.note.id,
            'imported_at': timestamp,
          }, conflictAlgorithm: ConflictAlgorithm.abort);
          onProgress?.call(
            KeepImportProgress(
              phase: KeepImportPhase.saving,
              completed: index + 1,
              total: prepared.length,
              message: 'Saving imported notes atomically…',
            ),
          );
        }
        cancellationToken.throwIfCancelled();
      });

      for (final lease in leases) {
        lease.markCommitted();
      }
      for (final label in createdLabels) {
        label.notifyWithOrigin('created', ModelChangeOrigin.migration);
      }
      for (final item in prepared) {
        item.note.notify('created', false, ModelChangeOrigin.migration);
      }
      unawaited(NoteSyncService().sync());
      unawaited(LabelSyncService().sync());
      return KeepPersistenceResult(
        imported: prepared.length,
        issues: List.unmodifiable(issues),
      );
    } catch (error) {
      for (final lease in leases) {
        await lease.releaseByCaller();
      }
      rethrow;
    }
  }

  String _encodeContent(KeepNoteDraft draft) {
    final delta = <Map<String, Object?>>[];
    if (draft.title.isNotEmpty) {
      delta
        ..add({'insert': draft.title})
        ..add({
          'insert': '\n',
          'attributes': {'header': 1},
        });
    }
    delta.addAll(draft.delta);
    return jsonEncode(documentFromJsonSafe(delta).toDelta().toJson());
  }

  bool _isImage(KeepAttachmentDraft attachment) {
    if (attachment.mimeType.startsWith('image/')) return true;
    const imageExtensions = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};
    return imageExtensions.contains(
      path.extension(attachment.archivePath).toLowerCase(),
    );
  }

  String _safeExtension(String filePath) {
    const audioExtensions = {'.mp3', '.wav', '.m4a', '.ogg'};
    final extension = path.extension(filePath).toLowerCase();
    return audioExtensions.contains(extension) ? extension : '.bin';
  }

  Color _mapColor(String colorName) => switch (colorName) {
    'RED' => const Color(0xFFF28B82),
    'ORANGE' => const Color(0xFFFBBC04),
    'YELLOW' => const Color(0xFFFFF475),
    'GREEN' => const Color(0xFFCCFF90),
    'TEAL' => const Color(0xFFA7FFEB),
    'BLUE' => const Color(0xFFCBF0F8),
    'CERULEAN' => const Color(0xFFAECBFA),
    'PURPLE' => const Color(0xFFD7AEFB),
    'PINK' => const Color(0xFFFDCFE8),
    'BROWN' => const Color(0xFFE6C9A8),
    'GRAY' => const Color(0xFFE8EAED),
    _ => Colors.transparent,
  };
}

class _PreparedKeepNote {
  final Note note;
  final String fingerprint;
  final Map<String, dynamic> row;

  const _PreparedKeepNote({
    required this.note,
    required this.fingerprint,
    required this.row,
  });
}
