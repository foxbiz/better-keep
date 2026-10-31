enum SyncEntityKind { note, label, order }

/// Logical edit identity shared by Firebase, local journal entries and encrypted
/// file manifests. Ciphertext representation does not participate in ordering.
class SyncVersion implements Comparable<SyncVersion> {
  SyncVersion({
    required this.kind,
    required this.entityId,
    required this.revisionId,
    required this.modifiedAtMicros,
    required this.deleted,
  }) {
    for (final value in [entityId, revisionId]) {
      if (value.isEmpty ||
          value.length > 256 ||
          RegExp(r'[\x00-\x1f]').hasMatch(value)) {
        throw const FormatException('Invalid sync identifier');
      }
    }
    if (modifiedAtMicros < 0 || modifiedAtMicros > 9007199254740991) {
      throw const FormatException('Invalid revision timestamp');
    }
  }
  final SyncEntityKind kind;
  final String entityId;
  final String revisionId;
  final int modifiedAtMicros;
  final bool deleted;

  @override
  int compareTo(SyncVersion other) {
    if (kind != other.kind || entityId != other.entityId) {
      throw ArgumentError('Cannot compare different sync entities');
    }
    var result = modifiedAtMicros.compareTo(other.modifiedAtMicros);
    if (result == 0) {
      result = (deleted ? 1 : 0).compareTo(other.deleted ? 1 : 0);
    }
    if (result == 0) result = revisionId.compareTo(other.revisionId);
    return result;
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'kind': kind.name,
    'entityId': entityId,
    'revisionId': revisionId,
    'modifiedAtMicros': modifiedAtMicros,
    'deleted': deleted,
  };
  factory SyncVersion.fromJson(Map<String, dynamic> value) {
    if (value['version'] != 1 ||
        value['entityId'] is! String ||
        value['revisionId'] is! String ||
        value['modifiedAtMicros'] is! int ||
        value['deleted'] is! bool) {
      throw const FormatException('Invalid sync version');
    }
    return SyncVersion(
      kind: SyncEntityKind.values.byName(value['kind'] as String),
      entityId: value['entityId'] as String,
      revisionId: value['revisionId'] as String,
      modifiedAtMicros: value['modifiedAtMicros'] as int,
      deleted: value['deleted'] as bool,
    );
  }
}
