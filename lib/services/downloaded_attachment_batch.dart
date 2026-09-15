import 'package:better_keep/models/file_sync_track.dart';
import 'package:better_keep/services/cloud_operation.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// Files are prepared outside SQLite; their canonical mappings move only in
/// the transaction that adopts the note references.
class DownloadedAttachmentBatch {
  final Database database;
  final NewAttachmentTransactionService files;
  final _changes = <String, _DownloadedAttachment>{};
  bool committed = false;

  DownloadedAttachmentBatch({required this.database, required this.files});

  FileSyncTrack? prepared(String source) => _changes[source]?.next;

  void add({
    required Map<String, Object?>? previous,
    required FileSyncTrack next,
    PreparedNewAttachmentFile? file,
  }) {
    _changes[next.remotePath!] = _DownloadedAttachment(previous, next, file);
  }

  Future<bool> commitMappings(Transaction txn) async {
    for (final change in _changes.values) {
      final rows = await txn.query(
        FileSyncTrack.model,
        where: 'remote_path = ?',
        whereArgs: [change.next.remotePath],
      );
      if (rows.length > 1 ||
          !mapEquals(rows.isEmpty ? null : rows.single, change.previous)) {
        return false;
      }
    }
    requireCloudOperation();
    for (final change in _changes.values) {
      await change.next.save(database: txn);
    }
    requireCloudOperation();
    return true;
  }

  Future<void> finish() async {
    for (final change in _changes.values) {
      final prepared = change.file;
      if (prepared == null) continue;
      try {
        if (committed) {
          await files.finishCommitted(prepared, database);
        } else {
          await files.rollback(prepared);
        }
      } catch (error, stack) {
        // Journal recovery retries cleanup; never turn a successful SQLite
        // commit into a failed remote apply just because cleanup was delayed.
        AppLogger.error('Downloaded attachment cleanup deferred', error, stack);
      }
    }
  }
}

class _DownloadedAttachment {
  final Map<String, Object?>? previous;
  final FileSyncTrack next;
  final PreparedNewAttachmentFile? file;

  _DownloadedAttachment(this.previous, this.next, this.file);
}
