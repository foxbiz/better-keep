import 'subscription_status.dart';
import 'user_plan.dart';

/// UID-bound copy of an entitlement returned by authenticated backend
/// verification. It is a local availability floor, not server authorization.
class VerifiedEntitlementSnapshot {
  const VerifiedEntitlementSnapshot({
    required this.uid,
    required this.status,
    required this.verifiedAt,
  });

  final String uid;
  final SubscriptionStatus status;
  final DateTime verifiedAt;

  bool isUsableFor(String expectedUid, {DateTime? now}) {
    final effectiveNow = now ?? DateTime.now();
    return uid == expectedUid &&
        status.plan == UserPlan.pro &&
        (status.isPlayStoreSubscription ||
            status.isAppStoreSubscription ||
            status.isRazorpaySubscription) &&
        status.expiresAt != null &&
        status.expiresAt!.isAfter(effectiveNow);
  }

  static VerifiedEntitlementSnapshot? fromBackend({
    required String uid,
    required Map<String, dynamic>? data,
    DateTime? verifiedAt,
  }) {
    final status = parseVerifiedProviderEntitlement(data);
    if (status == null) return null;
    return VerifiedEntitlementSnapshot(
      uid: uid,
      status: status,
      verifiedAt: verifiedAt ?? DateTime.now(),
    );
  }

  static VerifiedEntitlementSnapshot? fromJson(
    Map<String, dynamic>? data, {
    required String expectedUid,
    DateTime? now,
  }) {
    if (data == null ||
        data['entitlementContractVersion'] !=
            verifiedEntitlementContractVersion ||
        data['uid'] != expectedUid ||
        data['entitlement'] is! Map) {
      return null;
    }

    final entitlement = Map<String, dynamic>.from(data['entitlement'] as Map)
      ..['entitlementContractVersion'] = verifiedEntitlementContractVersion;
    final status = parseVerifiedProviderEntitlement(entitlement);
    final verifiedAt = DateTime.tryParse(data['verifiedAt']?.toString() ?? '');
    if (status == null || verifiedAt == null) return null;

    final snapshot = VerifiedEntitlementSnapshot(
      uid: expectedUid,
      status: status,
      verifiedAt: verifiedAt,
    );
    return snapshot.isUsableFor(expectedUid, now: now) ? snapshot : null;
  }

  Map<String, dynamic> toJson() => {
    'entitlementContractVersion': verifiedEntitlementContractVersion,
    'uid': uid,
    'verifiedAt': verifiedAt.toUtc().toIso8601String(),
    'entitlement': {
      ...status.toFirestore(),
      'entitlementContractVersion': verifiedEntitlementContractVersion,
    },
  };
}
