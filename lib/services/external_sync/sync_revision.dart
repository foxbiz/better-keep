import 'dart:convert';

import 'sync_limits.dart';

import 'sync_version.dart';
export 'sync_version.dart';

/// Provider-independent identity and ordering of an immutable content change.
/// Transport timestamps and provider cursors never participate in ordering.
class SyncRevision extends SyncVersion {
  SyncRevision({
    required super.kind,
    required super.entityId,
    required super.revisionId,
    required super.modifiedAtMicros,
    required super.deleted,
    required this.payloadObjectId,
    this.contentFingerprint,
    Iterable<String> legacyContentFingerprints = const [],
    Iterable<String> blobIds = const [],
  }) : legacyContentFingerprints = List.unmodifiable(
         legacyContentFingerprints.toSet().toList()..sort(),
       ),
       blobIds = List.unmodifiable(blobIds.toSet().toList()..sort()) {
    if (this.legacyContentFingerprints.length > 2 ||
        (this.legacyContentFingerprints.isNotEmpty &&
            contentFingerprint == null)) {
      throw const FormatException('Invalid legacy content fingerprints');
    }
    if (this.blobIds.length > SyncLimits.attachmentCount) {
      throw const FormatException('Too many sync attachments');
    }
    for (final id in [entityId, revisionId, ...this.blobIds]) {
      _validateId(id);
    }
    for (final id in [
      ...this.blobIds,
      ?payloadObjectId,
      ?contentFingerprint,
      ...this.legacyContentFingerprints,
    ]) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(id)) {
        throw const FormatException(
          'Object ID must be an encrypted SHA-256 digest',
        );
      }
    }
    if (modifiedAtMicros < 0 || modifiedAtMicros > 9007199254740991) {
      throw const FormatException('Invalid revision timestamp');
    }
    if (deleted) {
      if (payloadObjectId != null || this.blobIds.isNotEmpty) {
        throw const FormatException('Tombstones cannot reference content');
      }
    } else {
      if (payloadObjectId == null) {
        throw const FormatException('Missing revision payload');
      }
      _validateId(payloadObjectId!);
    }
  }

  /// IDs refer to immutable encrypted objects, never local paths or URLs.
  final String? payloadObjectId;
  final String? contentFingerprint;

  /// Authenticated aliases for the two pre-canonical portable number encodings.
  /// The codec validates these against the decrypted payload before applying it.
  final List<String> legacyContentFingerprints;
  final List<String> blobIds;

  static int nextTimestamp(DateTime now, SyncRevision? previous) {
    final time = now.toUtc().microsecondsSinceEpoch;
    return previous != null && previous.modifiedAtMicros >= time
        ? previous.modifiedAtMicros + 1
        : time;
  }

  /// Independently encrypted representations can share a logical revision only
  /// when their keyed content fingerprints match, including authenticated aliases
  /// for the old native/web number encodings. Unfingerprinted records stay strict.
  bool sameContent(SyncRevision other) =>
      kind == other.kind &&
      entityId == other.entityId &&
      compareTo(other) == 0 &&
      (contentFingerprint != null && other.contentFingerprint != null
          ? contentFingerprint == other.contentFingerprint ||
                legacyContentFingerprints.contains(other.contentFingerprint) ||
                other.legacyContentFingerprints.contains(contentFingerprint)
          : encode() == other.encode());

  @override
  Map<String, Object?> toJson() => {
    'version': 1,
    'kind': kind.name,
    'entityId': entityId,
    'revisionId': revisionId,
    'modifiedAtMicros': modifiedAtMicros,
    'deleted': deleted,
    'payloadObjectId': payloadObjectId,
    'blobIds': blobIds,
    if (contentFingerprint != null) 'contentFingerprint': contentFingerprint,
    if (legacyContentFingerprints.isNotEmpty)
      'legacyContentFingerprints': legacyContentFingerprints,
  };

  String encode() => jsonEncode(toJson());

  factory SyncRevision.decode(String value) {
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic> ||
        json['version'] != 1 ||
        json['entityId'] is! String ||
        json['revisionId'] is! String ||
        json['modifiedAtMicros'] is! int ||
        json['deleted'] is! bool ||
        (json['payloadObjectId'] != null &&
            json['payloadObjectId'] is! String) ||
        (json['contentFingerprint'] != null &&
            json['contentFingerprint'] is! String) ||
        (json['legacyContentFingerprints'] != null &&
            (json['legacyContentFingerprints'] is! List ||
                (json['legacyContentFingerprints'] as List).length > 2 ||
                (json['legacyContentFingerprints'] as List).any(
                  (value) => value is! String,
                ))) ||
        json['blobIds'] is! List ||
        (json['blobIds'] as List).length > SyncLimits.attachmentCount ||
        (json['blobIds'] as List).any((id) => id is! String)) {
      throw const FormatException('Invalid sync revision');
    }
    final kind = SyncEntityKind.values.where(
      (kind) => kind.name == json['kind'],
    );
    if (kind.length != 1) {
      throw const FormatException('Unknown sync entity kind');
    }
    return SyncRevision(
      kind: kind.single,
      entityId: json['entityId'] as String,
      revisionId: json['revisionId'] as String,
      modifiedAtMicros: json['modifiedAtMicros'] as int,
      deleted: json['deleted'] as bool,
      payloadObjectId: json['payloadObjectId'] as String?,
      contentFingerprint: json['contentFingerprint'] as String?,
      legacyContentFingerprints:
          (json['legacyContentFingerprints'] as List?)?.cast<String>() ??
          const [],
      blobIds: (json['blobIds'] as List).cast<String>(),
    );
  }

  static void _validateId(String id) {
    if (id.isEmpty || id.length > 256 || RegExp(r'[\x00-\x1f]').hasMatch(id)) {
      throw const FormatException('Invalid sync identifier');
    }
  }
}
