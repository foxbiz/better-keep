import 'package:better_keep/services/cloud_session_recovery.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Absence is actionable only after an acknowledged server read.
Future<DocumentSnapshot<Map<String, dynamic>>> readCloudDocument(
  DocumentReference<Map<String, dynamic>> reference, {
  bool Function()? isCurrent,
}) async {
  if (isCurrent != null) requireCurrentSession(isCurrent);
  final snapshot = await reference
      .get(const GetOptions(source: Source.server))
      .timeout(const Duration(seconds: 10));
  if (isCurrent != null) requireCurrentSession(isCurrent);
  if (snapshot.metadata.isFromCache || snapshot.metadata.hasPendingWrites) {
    throw const CloudVerificationUnavailable();
  }
  return snapshot;
}
