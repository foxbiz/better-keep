import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';

import 'sync_version.dart';
import 'sync_json.dart';

/// Bridges the existing Firebase wire format to provider-independent edit IDs.
/// Old clients use merge writes and can retain metadata from an earlier edit,
/// so metadata is trusted only while its complete wire payload still matches.
class FirebaseSyncVersion {
  static const field = 'sync_meta';
  static const _transportFields = {field, 'sync_committed_at', 'deleted_at'};

  static Map<String, dynamic> bind(
    Map<String, dynamic> payload,
    SyncVersion version,
  ) {
    final result = <String, dynamic>{
      ...payload,
      'updated_at': DateTime.fromMicrosecondsSinceEpoch(
        version.modifiedAtMicros,
        isUtc: true,
      ).toIso8601String(),
      if (version.deleted) 'deleted': true,
    };
    if (!version.deleted) {
      result.remove('deleted');
      result.remove('deleted_at');
    }
    result[field] = {
      ...version.toJson(),
      'payloadHash': _digest(result, legacy: true),
      'payloadHashV2': _digest(result),
    };
    return result;
  }

  static SyncVersion read(
    SyncEntityKind kind,
    String entityId,
    Map<String, dynamic> payload,
  ) {
    final digest = _digest(payload);
    final deleted = payload['deleted'] == true || payload['deleted'] == 1;
    final metadata = payload[field];
    if (metadata is Map &&
        (metadata.containsKey('payloadHashV2')
            ? metadata['payloadHashV2'] == digest
            : metadata['payloadHash'] == _digest(payload, legacy: true))) {
      try {
        final version = SyncVersion.fromJson(
          Map<String, dynamic>.from(metadata),
        );
        if (version.kind == kind &&
            version.entityId == entityId &&
            version.deleted == deleted &&
            version.modifiedAtMicros ==
                timestamp(payload['updated_at'])?.microsecondsSinceEpoch) {
          return version;
        }
      } on FormatException {
        // Malformed or stale metadata is an ordinary legacy writer's edit.
      } on ArgumentError {
        // Unknown kind or malformed metadata cannot replace wire identity.
      } on TypeError {
        // The legacy payload below must still have a valid timestamp.
      }
    }
    final modified =
        (deleted ? timestamp(payload['deleted_at']) : null) ??
        timestamp(payload['updated_at']) ??
        timestamp(payload['sync_committed_at']) ??
        (deleted ? DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true) : null);
    if (modified == null) {
      throw const MissingFirebaseSyncTimestamp();
    }
    final identity = sha256.convert(
      // The fallback stamp participates in ordering, so it must also be part
      // of the immutable identity. A delayed legacy-write trigger can change it.
      utf8.encode(
        jsonEncode([
          kind.name,
          entityId,
          digest,
          modified.microsecondsSinceEpoch,
        ]),
      ),
    );
    return SyncVersion(
      kind: kind,
      entityId: entityId,
      revisionId: 'firebase-$identity',
      modifiedAtMicros: modified.microsecondsSinceEpoch,
      deleted: deleted,
    );
  }

  /// A legacy wall-clock string has no recoverable timezone. Never guess using
  /// UTC or the receiving device's zone: prefer server commit/deletion stamps
  /// in read(), and defer records with no unambiguous timestamp.
  static DateTime? timestamp(Object? value) {
    if (value is Timestamp) return value.toDate().toUtc();
    if (value is DateTime) return value.toUtc();
    if (value is! String) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    return parsed.isUtc ? parsed : null;
  }

  /// Compare the content of two snapshots without transport-only markers.
  static bool samePayload(Map<String, dynamic> a, Map<String, dynamic> b) =>
      _digest(a) == _digest(b);

  static String _digest(Map<String, dynamic> value, {bool legacy = false}) {
    final canonical = _canonical({
      for (final entry in value.entries)
        if (!_transportFields.contains(entry.key)) entry.key: entry.value,
    });
    return sha256
        .convert(
          utf8.encode(
            legacy ? jsonEncode(canonical) : canonicalSyncJson(canonical),
          ),
        )
        .toString();
  }

  static Object? _canonical(Object? value) {
    if (value is Timestamp) return value.toDate().toUtc().toIso8601String();
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    if (value == null || value is String || value is bool || value is num) {
      return value;
    }
    throw const FormatException('Unsupported Firebase sync payload value');
  }
}

class MissingFirebaseSyncTimestamp extends FormatException {
  const MissingFirebaseSyncTimestamp()
    : super('Missing Firebase edit timestamp');
}
