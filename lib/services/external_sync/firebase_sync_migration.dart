import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../cloud_functions_helper.dart';
import '../cloud_read.dart';
import 'firebase_sync_version.dart';
import 'sync_version.dart';

/// Lazy, owner-scoped recovery of records created before server commit stamps.
/// Call only outside Firestore transactions. No receiver timezone is guessed.
class FirebaseSyncMigration {
  @visibleForTesting
  static Future<void> Function(SyncEntityKind kind, String entityId)?
  stampOverride;

  static Future<void> stamp(
    DocumentReference<Map<String, dynamic>> ref,
    SyncEntityKind kind,
    void Function() checkCurrent,
  ) async {
    checkCurrent();
    final override = stampOverride;
    if (override != null) {
      await override(kind, ref.id);
    } else {
      await callCloudFunction('stampLegacySyncDocument', {
        'kind': kind.name,
        'entityId': ref.id,
      });
    }
    checkCurrent();
  }

  static Future<Map<String, dynamic>> resolve(
    DocumentReference<Map<String, dynamic>> ref,
    SyncEntityKind kind,
    Map<String, dynamic> data,
    void Function() checkCurrent,
  ) async {
    try {
      FirebaseSyncVersion.read(kind, ref.id, data);
      return data;
    } on MissingFirebaseSyncTimestamp {
      await stamp(ref, kind, checkCurrent);
      final snapshot = await readCloudDocument(ref);
      checkCurrent();
      final latest = snapshot.data();
      // Never attach a newer edit's timestamp to cached old content. A changed
      // record must come through the normal listener/refetch path instead.
      if (latest == null || !FirebaseSyncVersion.samePayload(data, latest)) {
        throw const FormatException(
          'Firebase sync document changed during migration',
        );
      }
      FirebaseSyncVersion.read(kind, ref.id, latest);
      return latest;
    }
  }

  static Future<T> retry<T>(
    DocumentReference<Map<String, dynamic>> ref,
    SyncEntityKind kind,
    void Function() checkCurrent,
    Future<T> Function() operation,
  ) async {
    try {
      return await operation();
    } on MissingFirebaseSyncTimestamp {
      await stamp(ref, kind, checkCurrent);
      return operation();
    }
  }
}
