import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'note_lock_transaction_service.dart';

/// Native startup only, before readers/UI/sync, after recovery journals drain.
/// Never removes remote objects or the encrypted replica history.
class AttachmentStartupCleanup {
  static Future<void> run({
    required Database database,
    required NoteLockFileOperations operations,
    required Iterable<String> retiredPaths,
  }) async {
    final root = p.normalize(await operations.documentDirectory());
    final tracks = await database.query(
      'file_sync_track',
      columns: ['local_path'],
    );
    final materialized = await database.query(
      'replica_attachment_cache',
      columns: ['path'],
    );
    final candidates = <String>{...retiredPaths};
    for (final track in tracks) {
      candidates.add(track['local_path'] as String);
    }
    for (final row in materialized) {
      final path = p.normalize(await operations.resolve(row['path'] as String));
      if (p.isWithin(p.join(root, 'external_sync_media'), path)) {
        candidates.add(row['path'] as String);
      }
    }
    if (candidates.isEmpty) return;
    final references = <String>{};
    for (final path
        in await NoteFileReferenceService.databaseReferencedLocalPaths(
          database,
          includeSyncTracks: false,
        )) {
      references.add(p.normalize(await operations.resolve(path)));
    }
    var removed = 0;
    for (final candidate in candidates) {
      if (removed >= 256) break;
      final path = p.normalize(await operations.resolve(candidate));
      if (!p.isWithin(root, path) || references.contains(path)) continue;
      if (await operations.exists(path) && !await operations.delete(path)) {
        continue;
      }
      // Keep retry metadata if filesystem deletion fails.
      await database.transaction((txn) async {
        await txn.delete(
          'replica_attachment_cache',
          where: 'path = ?',
          whereArgs: [candidate],
        );
        await txn.delete(
          'file_sync_track',
          where: 'local_path = ?',
          whereArgs: [candidate],
        );
      });
      removed++;
    }
  }
}
