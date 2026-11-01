import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/shared_image_note_service.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Imports completed iOS extension batches, acknowledging only persisted notes.
class IosImageShareInbox {
  static const channel = MethodChannel('com.betterkeep/image_shares');
  final SharedImageNoteService imageNotes;

  final void Function(Object error)? onImportFailed;
  final void Function(Note note)? onImported;
  final void Function(bool busy)? onBusy;
  final _reportedFailures = <String>{};

  IosImageShareInbox(
    this.imageNotes, {
    this.onImportFailed,
    this.onImported,
    this.onBusy,
  });

  Future<int> importPending() async {
    final batches = await channel.invokeListMethod<dynamic>('pending') ?? [];
    if (batches.isEmpty) return 0;
    onBusy?.call(true);
    try {
      return await _importBatches(batches);
    } finally {
      onBusy?.call(false);
    }
  }

  Future<int> _importBatches(List<dynamic> batches) async {
    var imported = 0;
    Note? latestNote;
    for (final value in batches) {
      String? id;
      var saved = false;
      try {
        final batch = Map<String, dynamic>.from(value as Map);
        id = batch['id'] as String;
        // An interrupted acknowledgement must not duplicate an already saved note.
        if (await Note.findBySyncId(id) == null) {
          latestNote = await imageNotes.create(
            (batch['paths'] as List)
                .cast<String>()
                .map(
                  (path) =>
                      SharedMediaFile(path: path, type: SharedMediaType.image),
                )
                .toList(),
            shareId: id,
          );
          imported++;
        }
        saved = true;
        await channel.invokeMethod<void>('complete', id);
      } catch (error, stack) {
        AppLogger.error('[ImageShare] Batch import failed', error, stack);
        if (id == null || saved) continue;
        // The wrapper also carries I/O and platform failures. Only an explicit
        // invalid-input error may consume a permanent-failure attempt.
        final cause = error is SharedImageImportException ? error.cause : error;
        int? attempts;
        if (cause is FormatException) {
          try {
            attempts = await channel.invokeMethod<int>('failed', id);
            if (attempts != null && attempts >= 3) {
              AppLogger.log(
                '[ImageShare] Batch $id quarantined after $attempts failed imports',
              );
            }
          } catch (failure) {
            AppLogger.error(
              '[ImageShare] Could not record failed attempt',
              failure,
            );
          }
        }
        if ((attempts == null || attempts == 1) && _reportedFailures.add(id)) {
          onImportFailed?.call(error);
        }
      }
    }
    if (latestNote != null) onImported?.call(latestNote);
    return imported;
  }
}
