import 'dart:typed_data';

import 'package:better_keep/services/async_keyed_serializer.dart';
import 'package:better_keep/services/file_system_base.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'sync_cipher.dart';
import 'sync_revision.dart';

/// Persistent immutable encrypted objects. Content fingerprints are local-only
/// and scoped to the encryption library, avoiding duplicate media on each edit.
class SyncObjectCache {
  SyncObjectCache({
    required this.database,
    required this.files,
    required this.root,
    required this.scope,
    required this.cipher,
  });
  final Database database;
  final FileSystem files;
  final String root;
  final String scope;
  final SyncCipher cipher;
  final _writes = AsyncKeyedSerializer<String>();

  static Future<void> createTable(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS replica_object_sources (
      scope TEXT NOT NULL, fingerprint TEXT NOT NULL, object_id TEXT NOT NULL,
      PRIMARY KEY(scope, fingerprint))''');

  String _path(String id) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
      throw const FormatException('Invalid encrypted object ID');
    }
    return p.join(root, cipher.libraryId, 'objects', id);
  }

  Future<Uint8List?> read(String id) => _writes.run(id, () => _read(id));
  Future<Uint8List?> _read(String id) async {
    final path = _path(id);
    if (!await files.exists(path)) return null;
    final bytes = await files.readBytes(path);
    if (sha256.convert(bytes).toString() == id) return bytes;
    // A partial write or damaged cache can be repaired from an immutable remote.
    await files.delete(path);
    return null;
  }

  Future<void> write(String id, Uint8List bytes) => _writes.run(id, () async {
    if (sha256.convert(bytes).toString() != id) {
      throw const FormatException('Encrypted object hash mismatch');
    }
    if (await _read(id) != null) return;
    final path = _path(id);
    await files.createDirectory(p.dirname(path));
    await files.writeBytes(path, bytes);
  });

  Future<String> encrypt(Uint8List plaintext) async {
    final fingerprint = sha256.convert(plaintext).toString();
    // Serialize fingerprints separately from file writes to avoid lock recursion.
    return _writes.run('source:$fingerprint', () async {
      final rows = await database.query(
        'replica_object_sources',
        columns: ['object_id'],
        where: 'scope = ? AND fingerprint = ?',
        whereArgs: [scope, fingerprint],
      );
      if (rows.isNotEmpty) {
        final id = rows.single['object_id'] as String;
        if (await read(id) != null) return id;
      }
      final bytes = await cipher.encryptObject(plaintext);
      final id = sha256.convert(bytes).toString();
      await write(id, bytes);
      await database.insert('replica_object_sources', {
        'scope': scope,
        'fingerprint': fingerprint,
        'object_id': id,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return id;
    });
  }

  Future<Uint8List> decrypt(String id) async {
    final bytes = await read(id);
    if (bytes == null) {
      throw StateError('Required encrypted object is not cached');
    }
    return cipher.decryptObject(bytes);
  }

  /// Only call after the library's producers have stopped and drained, before
  /// starting its replacement session. Keep entities, pending downloads and
  /// every provider's last acknowledgement; attachment source files are not
  /// disposable cache and are deliberately outside this collector.
  Future<int> pruneUnreferenced({int limit = 256}) async {
    final referenced = await database.transaction((txn) async {
      final ids = <String>{};
      for (final table in [
        'replica_entities',
        'replica_inbox',
        'replica_acknowledgements',
      ]) {
        final rows = await txn.query(
          table,
          columns: ['revision'],
          where: 'scope = ?',
          whereArgs: [scope],
        );
        for (final row in rows) {
          final revision = SyncRevision.decode(row['revision'] as String);
          ids.addAll([...revision.blobIds, ?revision.payloadObjectId]);
        }
      }
      return ids;
    });
    var removed = 0;
    final directory = p.join(root, cipher.libraryId, 'objects');
    for (final entry in await files.list(directory)) {
      if (removed >= limit) break;
      // Native listings return paths; browser stores return child names.
      if (!p.isAbsolute(entry) && p.basename(entry) != entry) continue;
      final path = p.isAbsolute(entry) ? entry : p.join(directory, entry);
      final id = p.basename(path);
      if (p.normalize(p.dirname(path)) != p.normalize(directory) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(id) ||
          referenced.contains(id)) {
        continue;
      }
      if (await files.delete(path)) {
        await database.delete(
          'replica_object_sources',
          where: 'scope = ? AND object_id = ?',
          whereArgs: [scope, id],
        );
        removed++;
      }
    }
    return removed;
  }

  Future<void> waitForIdle() => _writes.waitForAll();
}
