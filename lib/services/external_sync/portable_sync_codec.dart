import 'sync_cipher.dart';
import 'sync_json.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:better_keep/models/note_sort.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

import 'sync_mutation_journal.dart';
import 'sync_object_cache.dart';
import 'sync_revision.dart';

typedef SyncFieldTransform = Future<String> Function(String);
typedef SyncAttachmentReader = Future<Uint8List> Function(String path);
typedef SyncAttachmentWriter = Future<String> Function(
  String entityId,
  String objectId,
  String extension,
  Uint8List bytes,
);

/// Only the note's existing PIN-authenticated migration can replace this source.
class SyncSourceRequiresUnlock implements Exception {
  const SyncSourceRequiresUnlock();
}

/// v1 payloads contain portable note fields and encrypted object references.
/// Local row IDs, filesystem paths, provider URLs and sketch previews are absent.
/// PIN ciphertext stays opaque inside the outer account encryption envelope.
class PortableSyncCodec {
  PortableSyncCodec({
    required this.cache,
    required this.readAttachment,
    required this.writeAttachment,
    SyncFieldTransform? decryptLocalField,
    SyncFieldTransform? encryptLocalField,
  }) : decryptLocalField =
           decryptLocalField ?? LocalDataEncryption.instance.decryptString,
       encryptLocalField =
           encryptLocalField ?? LocalDataEncryption.instance.encryptString;
  final SyncObjectCache cache;
  final SyncAttachmentReader readAttachment;
  final SyncAttachmentWriter writeAttachment;
  final SyncFieldTransform decryptLocalField;
  final SyncFieldTransform encryptLocalField;

  static const _noteText = ['title', 'labels', 'color'];
  static const _noteFlags = [
    'locked',
    'pinned',
    'trashed',
    'archived',
    'read_only',
    'completed',
  ];
  static const _attachmentFields = {
    'image': [
      'size',
      'index',
      'aspectRatio',
      'lastModified',
      'blurredThumbnail',
    ],
    'audio': ['length', 'title', 'transcript'],
    'sketch': [
      'aspectRatio',
      'blurredThumbnail',
      'strokesContentHash',
      'encryptedStrokes',
      'bgColor',
      'pagePattern',
    ],
  };
  static const _fileFields = {
    'image': ['src'],
    'audio': ['src'],
    'sketch': ['strokesFilePath', 'backgroundImage'],
  };

  Future<SyncRevision> encode(
    SyncLocalVersion version,
    Map<String, Object?>? row, {
    List<String> orderedIds = const [],
  }) async {
    if (version.deleted) return version.materialize();
    if (row == null) throw StateError('Local sync content is missing');
    final blobs = <String>{};
    late Map<String, dynamic> data;
    switch (version.kind) {
      case SyncEntityKind.note:
        data = {
          for (final field in _noteText) field: row[field] ?? '',
          for (final field in _noteFlags) field: row[field] ?? 0,
          'content': await _decrypt(row['content'] as String? ?? ''),
          'created_at': _utc(row['created_at'], version.modifiedAtMicros),
          'reminder': _reminder(row['reminder']),
          'attachments': <Map<String, dynamic>>[],
        };
        final raw = await _decrypt(row['attachments'] as String? ?? '[]');
        final attachments = jsonDecode(raw);
        if (attachments is! List) {
          throw const FormatException('Invalid note attachments');
        }
        for (final value in attachments) {
          if (value is! Map) throw const FormatException('Invalid attachment');
          final type = value['type'];
          if (!_fileFields.containsKey(type)) {
            throw const FormatException('Unsupported attachment');
          }
          final rawData = value['data'];
          if (rawData is! Map && !(rawData is String && type == 'audio')) {
            throw const FormatException('Invalid attachment data');
          }
          final source = rawData is String && type == 'audio'
              ? <String, dynamic>{'src': rawData}
              : Map<String, dynamic>.from(rawData as Map);
          if (type == 'audio' && source['src'] == null) {
            source['src'] = source['path'];
          }
          if (type == 'sketch' &&
              data['locked'] == 1 &&
              source['encrypted_metadata'] != null) {
            // Only the existing PIN-authenticated migration may open this
            // deprecated device-key source. Another device cannot decrypt it,
            // and a second source is not proof that the drawings are identical.
            throw const SyncSourceRequiresUnlock();
          }
          final portable = {
            for (final field in _attachmentFields[type]!)
              if (source[field] != null) field: source[field],
          };
          if (type == 'audio') portable['length'] = source['length'] ?? 0;
          if (type == 'sketch') {
            portable['aspectRatio'] =
                (source['aspectRatio'] as num?)?.toDouble() ?? 1.0;
          }
          // Unlocked legacy inline sketch metadata is converted into the source
          // file format. Legacy PIN ciphertext remains opaque and portable.
          if (type == 'sketch' &&
              (source['strokesFilePath'] == null ||
                  source['strokesFilePath'] == '') &&
              data['locked'] == 0 &&
              (source['encrypted_metadata'] is String ||
                  source['strokes'] is List)) {
            final metadata = source['encrypted_metadata'] is String
                ? await _decrypt(source['encrypted_metadata'] as String)
                : jsonEncode({
                    'strokes': source['strokes'],
                    'bgColor': source['bgColor'] ?? 0xFFFFFFFF,
                    'pagePattern': source['pagePattern'] ?? 'blank',
                    'aspectRatio': source['aspectRatio'] ?? 1.0,
                  });
            final bytes = Uint8List.fromList(utf8.encode(metadata));
            final id = await cache.encrypt(bytes);
            portable['strokesFilePath'] = {
              'objectId': id,
              'contentHash': sha256.convert(bytes).toString(),
              'extension': '.json',
            };
            blobs.add(id);
          }
          for (final field in _fileFields[type]!) {
            final path = source[field];
            if (path == null || path == '') continue;
            if (path is! String) {
              throw const FormatException('Invalid attachment source');
            }
            final bytes = await readAttachment(path);
            if (bytes.isEmpty) {
              throw StateError('Attachment source is unavailable');
            }
            // Legacy Firebase paths can be overwritten by older clients. When
            // the note names a source hash, never capture a different drawing
            // under this note revision. Local edits may still carry an old hash.
            final expectedHash = source['strokesContentHash'];
            if (field == 'strokesFilePath' &&
                expectedHash != null &&
                const {
                  'gs',
                  'http',
                  'https',
                }.contains(Uri.tryParse(path)?.scheme) &&
                sha256.convert(bytes).toString() != expectedHash) {
              throw const FormatException('Attachment source changed remotely');
            }
            final id = await cache.encrypt(bytes);
            blobs.add(id);
            final extension = p
                .extension(Uri.tryParse(path)?.path ?? path)
                .toLowerCase();
            portable[field] = {
              'objectId': id,
              'contentHash': sha256.convert(bytes).toString(),
              'extension': _extension(extension) ? extension : '.bin',
            };
          }
          if ((type == 'image' || type == 'audio') && portable['src'] == null) {
            throw const FormatException('Missing attachment source');
          }
          if (type == 'sketch' &&
              portable['strokesFilePath'] == null &&
              portable['encryptedStrokes'] == null) {
            throw const FormatException('Missing sketch source');
          }
          (data['attachments'] as List).add({
            'type': type,
            if (value['id'] != null) 'id': value['id'],
            'data': portable,
          });
        }
      case SyncEntityKind.label:
        data = {
          'name': row['name'],
          'is_system': row['is_system'] ?? 0,
          'created_at': _utc(row['created_at'], version.modifiedAtMicros),
        };
      case SyncEntityKind.order:
        data = {'sort_mode': row['sort_mode'], 'ordered_ids': orderedIds};
    }
    final payload = {
      'version': 1,
      'kind': version.kind.name,
      'entityId': version.entityId,
      'data': data,
    };
    final id = await cache.encrypt(
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    return version.materialize(
      payloadObjectId: id,
      blobIds: blobs,
      contentFingerprint: _fingerprint(payload, cache.cipher),
      legacyContentFingerprints: _legacyFingerprints(payload, cache.cipher),
    );
  }

  /// Produces only supported local columns; never accepts paths supplied by a
  /// remote payload. All source files must be authenticated commit dependencies.
  Future<Map<String, Object?>> decode(SyncRevision revision) async {
    if (revision.deleted) return {};
    final payloadJson = utf8.decode(
      await cache.decrypt(revision.payloadObjectId!),
    );
    final decoded = _validatePayload(revision, payloadJson, cache.cipher);
    final data = Map<String, dynamic>.from(decoded['data'] as Map);
    final timestamp = DateTime.fromMicrosecondsSinceEpoch(
      revision.modifiedAtMicros,
      isUtc: true,
    ).toIso8601String();
    switch (revision.kind) {
      case SyncEntityKind.note:
        for (final field in _noteText) {
          if (data[field] is! String) {
            throw const FormatException('Invalid note text');
          }
        }
        for (final field in _noteFlags) {
          if (data[field] != 0 && data[field] != 1) {
            throw const FormatException('Invalid note flag');
          }
        }
        if (data['content'] is! String || data['attachments'] is! List) {
          throw const FormatException('Invalid note body');
        }
        final attachments = <Map<String, dynamic>>[];
        final used = <String>{};
        for (final value in data['attachments'] as List) {
          if (value is! Map ||
              !_fileFields.containsKey(value['type']) ||
              value['data'] is! Map ||
              (value['id'] != null && value['id'] is! String)) {
            throw const FormatException('Invalid portable attachment');
          }
          final type = value['type'] as String;
          final source = Map<String, dynamic>.from(value['data'] as Map);
          if (source.containsKey('encrypted_metadata')) {
            throw const FormatException(
              'Device-key sketch metadata is not portable',
            );
          }
          final local = <String, dynamic>{
            for (final field in _attachmentFields[type]!)
              if (source[field] != null) field: source[field],
          };
          for (final field in _fileFields[type]!) {
            final ref = source[field];
            if (ref == null) continue;
            if (ref is! Map ||
                ref['objectId'] is! String ||
                !revision.blobIds.contains(ref['objectId']) ||
                ref['contentHash'] is! String ||
                !RegExp(r'^[0-9a-f]{64}$')
                    .hasMatch(ref['contentHash'] as String) ||
                ref['extension'] is! String ||
                !_extension(ref['extension'] as String)) {
              throw const FormatException(
                'Invalid attachment object reference',
              );
            }
            final id = ref['objectId'] as String;
            used.add(id);
            final bytes = await cache.decrypt(id);
            if (sha256.convert(bytes).toString() != ref['contentHash']) {
              throw const FormatException(
                'Attachment content fingerprint mismatch',
              );
            }
            local[field] = await writeAttachment(
              revision.entityId,
              id,
              ref['extension'] as String,
              bytes,
            );
          }
          if (type == 'sketch') local['previewImage'] = null;
          final attachment = <String, dynamic>{
            'type': type,
            if (value['id'] != null) 'id': value['id'],
            'data': local,
          };
          NoteAttachment.fromJson(
            attachment,
          ); // Validate fields before a domain write.
          attachments.add(attachment);
        }
        if (used.length != revision.blobIds.length) {
          throw const FormatException('Unexpected attachment dependencies');
        }
        return {
          'sync_id': revision.entityId,
          for (final field in _noteText) field: data[field],
          for (final field in _noteFlags) field: data[field],
          'content': await encryptLocalField(data['content'] as String),
          'plain_text': data['locked'] == 1
              ? ''
              : _plainText(data['content'] as String),
          'attachments': jsonEncode(attachments),
          'reminder': data['reminder'] == null
              ? null
              : jsonEncode(_reminder(data['reminder'])),
          'created_at': _utc(data['created_at'], revision.modifiedAtMicros),
          'updated_at': timestamp,
        };
      case SyncEntityKind.label:
        if (data['name'] is! String ||
            (data['is_system'] != 0 && data['is_system'] != 1) ||
            revision.blobIds.isNotEmpty) {
          throw const FormatException('Invalid label payload');
        }
        return {
          'sync_id': revision.entityId,
          'name': data['name'],
          'is_system': data['is_system'],
          'created_at': _utc(data['created_at'], revision.modifiedAtMicros),
          'updated_at': timestamp,
        };
      case SyncEntityKind.order:
        if (NoteOrderContext.tryParse(revision.entityId) == null ||
            !NoteSortMode.values.any((m) => m.name == data['sort_mode']) ||
            data['ordered_ids'] is! List ||
            (data['ordered_ids'] as List).any(
              (id) => id is! String || id.isEmpty || id.length > 256,
            ) ||
            revision.blobIds.isNotEmpty) {
          throw const FormatException('Invalid order payload');
        }
        final ids = (data['ordered_ids'] as List).cast<String>();
        if (ids.toSet().length != ids.length) {
          throw const FormatException('Duplicate ordered note identity');
        }
        return {
          'context_key': revision.entityId,
          'sort_mode': data['sort_mode'],
          'revision': revision.revisionId,
          'base_revision': null,
          'updated_at': timestamp,
          'dirty': 1,
          'hydrated': 1,
          'ordered_ids': ids,
        };
    }
  }

  /// Upgrade only the in-memory representation of a legacy commit. Its object,
  /// source edit ID and remote file remain immutable. This also repairs comparisons
  /// against already persisted acknowledgements made before canonical numbers.
  static SyncRevision normalizeFingerprint(
    SyncCipher cipher,
    SyncRevision revision,
    Uint8List plaintext,
  ) {
    final payload = _validatePayload(revision, utf8.decode(plaintext), cipher);
    return SyncRevision(
      kind: revision.kind,
      entityId: revision.entityId,
      revisionId: revision.revisionId,
      modifiedAtMicros: revision.modifiedAtMicros,
      deleted: revision.deleted,
      payloadObjectId: revision.payloadObjectId,
      blobIds: revision.blobIds,
      contentFingerprint: _fingerprint(payload, cipher),
      legacyContentFingerprints: _legacyFingerprints(payload, cipher),
    );
  }

  static Map _validatePayload(
    SyncRevision revision,
    String payloadJson,
    SyncCipher cipher,
  ) {
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['kind'] != revision.kind.name ||
        decoded['entityId'] != revision.entityId ||
        decoded['data'] is! Map) {
      throw const FormatException('Invalid portable sync payload');
    }
    if (revision.contentFingerprint == null ||
        !revision.legacyContentFingerprints.every(
          _legacyFingerprints(decoded, cipher).contains,
        ) ||
        (revision.contentFingerprint != _fingerprint(decoded, cipher) &&
            revision.contentFingerprint !=
                _fingerprint(
                  decodeLegacyFingerprintJson(payloadJson) as Map,
                  cipher,
                ))) {
      throw const FormatException('Portable content fingerprint mismatch');
    }
    return decoded;
  }

  static Set<String> _legacyFingerprints(Map payload, SyncCipher cipher) => {
    _fingerprint(payload, cipher, legacyNative: true),
    _fingerprint(payload, cipher, legacyNative: false),
  };

  static String _fingerprint(
    Map payload,
    SyncCipher cipher, {
    bool? legacyNative,
  }) {
    final normalized = Map<String, dynamic>.from(payload);
    final data = Map<String, dynamic>.from(payload['data'] as Map);
    normalized['data'] = data;
    if (payload['kind'] == SyncEntityKind.note.name &&
        data['attachments'] is List) {
      data['attachments'] = (data['attachments'] as List).map((value) {
        if (value is! Map || value['data'] is! Map) {
          throw const FormatException('Invalid portable attachment');
        }
        final attachment = Map<String, dynamic>.from(value);
        final source = Map<String, dynamic>.from(value['data'] as Map);
        attachment['data'] = source;
        // Derived presentation and file representation do not create an edit.
        source.remove('blurredThumbnail');
        source.remove('strokesContentHash');
        if (legacyNative != null &&
            value['type'] == 'sketch' &&
            source['aspectRatio'] is num) {
          source['aspectRatio'] = legacySyncDouble(
            source['aspectRatio'] as num,
            native: legacyNative,
          );
        }
        for (final field in _fileFields[value['type']] ?? const <String>[]) {
          final ref = source[field];
          if (ref == null) continue;
          if (ref is! Map || ref['contentHash'] is! String) {
            throw const FormatException(
              'Missing attachment content fingerprint',
            );
          }
          source[field] = {'contentHash': ref['contentHash']};
        }
        return attachment;
      }).toList();
    }
    return cipher.contentFingerprint(
      utf8.encode(
        canonicalSyncJson(normalized, legacyNumbers: legacyNative != null),
      ),
    );
  }

  static String _plainText(String content) {
    try {
      final delta = jsonDecode(content);
      return delta is List ? noteDeltaPlainText(delta) : content;
    } on FormatException {
      return content;
    }
  }

  Future<String> _decrypt(String text) async {
    final plain = await decryptLocalField(text);
    if (LocalDataEncryption.isEncrypted(text) &&
        (plain.isEmpty || plain == text)) {
      throw StateError('Local encrypted content could not be read');
    }
    return plain;
  }

  static bool _extension(String value) =>
      RegExp(r'^\.[a-z0-9]{1,12}$').hasMatch(value);
  static String _utc(Object? value, int fallback) =>
      (DateTime.tryParse(value?.toString() ?? '') ??
              DateTime.fromMicrosecondsSinceEpoch(fallback, isUtc: true))
          .toUtc()
          .toIso8601String();
  static Map<String, Object?>? _reminder(Object? value) {
    if (value == null) return null;
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is! Map) throw const FormatException('Invalid reminder');
    return Reminder.fromJson(Map<String, Object?>.from(decoded)).toJson();
  }
}
