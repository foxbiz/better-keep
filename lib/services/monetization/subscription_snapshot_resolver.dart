import 'subscription_status.dart';
import 'user_plan.dart';

class SubscriptionSnapshotResolution {
  const SubscriptionSnapshotResolution({
    required this.status,
    required this.retainVerifiedSnapshot,
    this.canonicalProviderCaughtUp = false,
    this.shouldReconcile = false,
  });

  final SubscriptionStatus status;
  final bool retainVerifiedSnapshot;
  final bool canonicalProviderCaughtUp;
  final bool shouldReconcile;
}

/// Enforces monotonic paid access across Firestore cache/server races.
///
/// Only an explicit terminal backend result may replace an unexpired provider
/// entitlement with trial/free. Firestore missing/trial/expired snapshots are
/// treated as potentially stale and cause reconciliation instead.
SubscriptionSnapshotResolution resolveSubscriptionSnapshot({
  required SubscriptionStatus current,
  required SubscriptionStatus? incoming,
  SubscriptionStatus? verified,
  bool explicitTerminal = false,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  final verifiedActive = _isActiveProviderAt(verified, effectiveNow);
  final currentActive = _isActiveProviderAt(current, effectiveNow);
  final incomingActive = _isActiveProviderAt(incoming, effectiveNow);

  if (explicitTerminal) {
    return SubscriptionSnapshotResolution(
      status: incoming ?? SubscriptionStatus.free,
      retainVerifiedSnapshot: false,
    );
  }

  if (incomingActive) {
    return SubscriptionSnapshotResolution(
      status: incoming!,
      retainVerifiedSnapshot: false,
      canonicalProviderCaughtUp: true,
    );
  }

  final paidFloor = verifiedActive
      ? verified!
      : currentActive
      ? current
      : null;
  if (paidFloor != null) {
    return SubscriptionSnapshotResolution(
      status: paidFloor,
      retainVerifiedSnapshot: verifiedActive,
      shouldReconcile: true,
    );
  }

  return SubscriptionSnapshotResolution(
    status: incoming ?? SubscriptionStatus.free,
    retainVerifiedSnapshot: verifiedActive,
  );
}

bool _isActiveProviderAt(SubscriptionStatus? status, DateTime now) {
  if (status == null ||
      status.plan != UserPlan.pro ||
      status.expiresAt == null ||
      !status.expiresAt!.isAfter(now)) {
    return false;
  }
  return status.isPlayStoreSubscription ||
      status.isAppStoreSubscription ||
      status.isRazorpaySubscription;
}
