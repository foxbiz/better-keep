import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../../utils/encryption.dart';
import '../attachment_storage_repository.dart';
import '../e2ee/crypto_primitives.dart';
import 'portable_sync_codec.dart';
import 'sync_attachment_store.dart';
import 'sync_replica_engine.dart';

/// Imports an existing Firebase source into the portable object cache. This is
/// independent of Firebase library sync selection and its upload entitlement.
/// No mutable URL cache or local note update is needed: the caller captures the
/// bytes in an immutable revision only while its source version is still current.
class FirebaseAttachmentReader {
  FirebaseAttachmentReader({
    required this.uid,
    required this.storage,
    required this.readLocal,
    required this.readKey,
    required this.isCurrent,
    this.database,
  });

  final String uid;
  final AttachmentStorageRepository storage;
  final SyncAttachmentReader readLocal;
  final Uint8List? Function() readKey;
  final bool Function() isCurrent;
  final Database? database;

  static bool isRemote(String source) =>
      const {'gs', 'http', 'https'}.contains(Uri.tryParse(source)?.scheme);

  void _guard() {
    if (!isCurrent()) throw const SyncReplicaCancelled();
  }

  Future<Uint8List> read(String source) async {
    _guard();
    if (isRemote(source)) return _readRemote(source);
    try {
      final bytes = await readLocal(source);
      _guard();
      return bytes;
    } on SyncAttachmentMissing catch (missing) {
      _guard();
      final db = database;
      if (db == null) rethrow;
      // Use the session's database, never the mutable global AppState DB.
      // Multiple conflicting mappings or old rows without a hash cannot prove
      // which bytes belong to this source and must stay pending.
      final rows = await db.query(
        'file_sync_track',
        distinct: true,
        columns: ['remote_path', 'content_hash'],
        where: 'local_path IN (?, ?)',
        whereArgs: [source, missing.path],
        limit: 2,
      );
      _guard();
      if (rows.length != 1) rethrow;
      final remote = rows.single['remote_path'];
      final hash = rows.single['content_hash'];
      if (remote is! String ||
          !isRemote(remote) ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        rethrow;
      }
      final bytes = await _readRemote(remote);
      if (sha256.convert(bytes).toString() != hash) {
        throw const FormatException('Attachment source has changed');
      }
      return bytes;
    }
  }

  Future<Uint8List> _readRemote(String source) async {
    _guard();
    // Resolve through the configured Storage SDK, never through a bearer URL.
    final locator = storage.parse(source);
    if (!locator.fullPath.startsWith('users/$uid/notes/')) {
      throw const FormatException('Attachment belongs to another library');
    }
    final bytes = await storage
        .download(source)
        .timeout(const Duration(seconds: 120));
    _guard();
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('Attachment source is unavailable');
    }
    // Firebase's older format has no envelope marker: the first bytes are a
    // random nonce, so a recognizable file signature cannot rule out encryption.
    final key = readKey();
    if (key == null || key.length != 32) {
      throw const FormatException('Attachment encryption key is unavailable');
    }
    final copy = Uint8List.fromList(key);
    try {
      late Uint8List plaintext;
      try {
        plaintext = await FileEncryption.decryptBytes(bytes, copy);
      } catch (_) {
        _guard();
        // Only after authentication fails may a legacy plaintext/PIN source
        // pass through. Unknown binary data remains an error.
        if (isBytesPasswordEncrypted(bytes) ||
            !FileEncryption.looksEncrypted(bytes)) {
          return bytes;
        }
        rethrow;
      }
      _guard();
      if (plaintext.isEmpty) {
        throw const FormatException('Attachment source is unavailable');
      }
      return plaintext;
    } finally {
      copy.fillRange(0, copy.length, 0);
    }
  }
}
