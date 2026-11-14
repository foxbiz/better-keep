import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../async_keyed_serializer.dart';
import '../file_system_base.dart';
import '../local_data_encryption.dart';
import '../../utils/file_utils.dart';
import 'sync_replica_engine.dart';

/// A validated app path has no local source. Other read/decryption failures
/// must not silently fall back to an older cloud copy.
class SyncAttachmentMissing implements Exception {
  const SyncAttachmentMissing(this.path);
  final String path;
}

/// Materializes verified portable media into ordinary app attachment files.
/// The index is only a cache: a file edited or removed locally must be verified
/// again before reuse. Separate note identities never share a mutable file.
class SyncAttachmentStore {
  SyncAttachmentStore({
    required this.database,
    required this.files,
    required this.scope,
    required this.root,
    required this.allowedSourceRoots,
    required this.isCurrent,
    Future<Uint8List> Function(Uint8List)? encrypt,
    Future<Uint8List> Function(Uint8List)? decrypt,
    Future<bool> Function()? encryptionEnabled,
    Future<String> Function(String)? normalizePath,
  }) : encrypt = encrypt ?? LocalDataEncryption.instance.encryptBytes,
       decrypt = decrypt ?? LocalDataEncryption.instance.decryptBytes,
       encryptionEnabled =
           encryptionEnabled ?? LocalDataEncryption.instance.isFilesEnabled,
       normalizePath = normalizePath ?? FileUtils.fixPath;

  final Database database;
  final FileSystem files;
  final String scope;
  final String root;
  final List<String> allowedSourceRoots;
  final bool Function() isCurrent;
  final Future<Uint8List> Function(Uint8List) encrypt;
  final Future<Uint8List> Function(Uint8List) decrypt;
  final Future<bool> Function() encryptionEnabled;
  final Future<String> Function(String) normalizePath;
  final _writes = AsyncKeyedSerializer<String>();

  static Future<void> createTable(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS replica_attachment_cache (
      scope TEXT NOT NULL, entity_id TEXT NOT NULL, object_id TEXT NOT NULL,
      path TEXT NOT NULL, PRIMARY KEY(scope, entity_id, object_id))
  ''');

  void _guard() {
    if (!isCurrent()) throw const SyncReplicaCancelled();
  }

  Future<Uint8List> read(String source) async {
    _guard();
    final path = p.normalize(await normalizePath(source));
    _guard();
    if (!allowedSourceRoots.any(
      (root) => p.isWithin(p.normalize(root), path),
    )) {
      throw const FormatException('Attachment is outside app storage');
    }
    final exists = await files.exists(path);
    _guard();
    if (!exists) throw SyncAttachmentMissing(path);
    final stored = await files.readBytes(path);
    _guard();
    final bytes = await decrypt(stored);
    _guard();
    if (bytes.isEmpty) {
      throw const FormatException('Attachment source is unavailable');
    }
    return bytes;
  }

  Future<String> materialize(
    String entityId,
    String objectId,
    String extension,
    Uint8List bytes,
  ) {
    if (entityId.isEmpty ||
        entityId.length > 256 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(objectId) ||
        !RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension) ||
        bytes.isEmpty) {
      throw const FormatException('Invalid attachment identity');
    }
    return _writes.run('$entityId:$objectId', () async {
      _guard();
      final protect = await encryptionEnabled();
      _guard();
      final matches = await database.query(
        'replica_attachment_cache',
        columns: ['path'],
        where: 'scope = ? AND entity_id = ? AND object_id = ?',
        whereArgs: [scope, entityId, objectId],
      );
      _guard();
      final expectedHash = sha256.convert(bytes);
      if (matches.isNotEmpty) {
        try {
          final path = p.normalize(
            await normalizePath(matches.single['path'] as String),
          );
          _guard();
          if (p.isWithin(p.normalize(root), path) && await files.exists(path)) {
            final stored = await files.readBytes(path);
            _guard();
            final restored = await decrypt(stored);
            _guard();
            if (sha256.convert(restored) == expectedHash &&
                (!protect || LocalDataEncryption.isBytesEncrypted(stored))) {
              return path;
            }
          }
        } on SyncReplicaCancelled {
          rethrow;
        } catch (_) {
          // This index is a hint, not the source of truth. Recreate missing or
          // damaged files from the already verified portable object.
          _guard();
        }
      }
      final stored = await encrypt(bytes);
      _guard();
      if (protect && !LocalDataEncryption.isBytesEncrypted(stored)) {
        throw const FormatException('Local attachment encryption failed');
      }
      if (sha256.convert(await decrypt(stored)) != expectedHash) {
        throw const FormatException(
          'Local attachment encryption did not round trip',
        );
      }
      _guard();
      final path = p.join(root, '${const Uuid().v4()}$extension');
      var indexed = false;
      try {
        await files.createDirectory(root);
        _guard();
        await files.writeBytes(path, stored);
        _guard();
        if (sha256.convert(await read(path)) != expectedHash) {
          throw const FormatException(
            'Local attachment write failed verification',
          );
        }
        await database.transaction((txn) async {
          _guard();
          await txn.insert('replica_attachment_cache', {
            'scope': scope,
            'entity_id': entityId,
            'object_id': objectId,
            'path': path,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          _guard();
        });
        // Once indexed, another operation can legitimately reuse this file.
        // A later session change must not delete that shared committed entry.
        indexed = true;
        _guard();
        return path;
      } finally {
        if (!indexed) await files.delete(path);
      }
    });
  }

  /// Drain filesystem work before the owning account deletes its local files.
  Future<void> waitForIdle() => _writes.waitForAll();
}
