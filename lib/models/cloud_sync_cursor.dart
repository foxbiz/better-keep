import 'package:cloud_firestore/cloud_firestore.dart';

/// Metadata written on every cloud mutation and used exclusively for sync
/// discovery. Content conflict resolution continues to use `updated_at`.
const String cloudSyncCommittedAtField = 'sync_committed_at';

/// An exact, deterministic position in a Firestore sync stream.
///
/// Firestore timestamps have nanosecond precision, so converting them to
/// [DateTime] would lose precision. The document ID is the tie-breaker for
/// writes that receive the same server timestamp.
class CloudSyncCursor implements Comparable<CloudSyncCursor> {
  const CloudSyncCursor({
    required this.seconds,
    required this.nanoseconds,
    required this.documentId,
  });

  final int seconds;
  final int nanoseconds;
  final String documentId;

  Timestamp get timestamp => Timestamp(seconds, nanoseconds);

  static CloudSyncCursor? fromDocument(
    Map<String, dynamic> data,
    String documentId,
  ) {
    final committedAt = data[cloudSyncCommittedAtField];
    if (committedAt is! Timestamp) return null;

    return CloudSyncCursor(
      seconds: committedAt.seconds,
      nanoseconds: committedAt.nanoseconds,
      documentId: documentId,
    );
  }

  factory CloudSyncCursor.fromJson(Map<String, dynamic> json) {
    return CloudSyncCursor(
      seconds: (json['seconds'] as num).toInt(),
      nanoseconds: (json['nanoseconds'] as num).toInt(),
      documentId: json['document_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'seconds': seconds,
      'nanoseconds': nanoseconds,
      'document_id': documentId,
    };
  }

  @override
  int compareTo(CloudSyncCursor other) {
    final secondsComparison = seconds.compareTo(other.seconds);
    if (secondsComparison != 0) return secondsComparison;

    final nanosecondsComparison = nanoseconds.compareTo(other.nanoseconds);
    if (nanosecondsComparison != 0) return nanosecondsComparison;

    return documentId.compareTo(other.documentId);
  }

  CloudSyncCursor max(CloudSyncCursor other) {
    return compareTo(other) >= 0 ? this : other;
  }

  @override
  bool operator ==(Object other) {
    return other is CloudSyncCursor &&
        seconds == other.seconds &&
        nanoseconds == other.nanoseconds &&
        documentId == other.documentId;
  }

  @override
  int get hashCode => Object.hash(seconds, nanoseconds, documentId);
}

/// Durable sync state for one remote collection.
///
/// A bootstrapped checkpoint with a null [cursor] is valid: it means the
/// legacy full reconciliation completed while no stamped documents existed.
class CloudSyncCheckpoint {
  const CloudSyncCheckpoint({required this.bootstrapped, this.cursor});

  static const int schemaVersion = 2;

  final bool bootstrapped;
  final CloudSyncCursor? cursor;

  bool get requiresBootstrap => !bootstrapped;

  CloudSyncCheckpoint advanceTo(CloudSyncCursor candidate) {
    final current = cursor;
    return CloudSyncCheckpoint(
      bootstrapped: true,
      cursor: current == null ? candidate : current.max(candidate),
    );
  }

  factory CloudSyncCheckpoint.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != schemaVersion) {
      throw const FormatException('Unsupported cloud sync checkpoint');
    }

    final cursorJson = json['cursor'];
    return CloudSyncCheckpoint(
      bootstrapped: json['bootstrapped'] as bool? ?? false,
      cursor: cursorJson is Map
          ? CloudSyncCursor.fromJson(Map<String, dynamic>.from(cursorJson))
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schema_version': schemaVersion,
      'bootstrapped': bootstrapped,
      'cursor': cursor?.toJson(),
    };
  }
}
