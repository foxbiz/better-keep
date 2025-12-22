import 'user_plan.dart';

/// Immutable entitlements model defining what features a user can access.
///
/// This is the SINGLE SOURCE OF TRUTH for feature access.
/// All feature gating in the app should use this model.
///
/// Pro features:
/// - Unlimited locked notes (Free: 5 max)
/// - Real-time cloud sync with E2EE (Free: no cloud sync)
class Entitlements {
  /// Maximum number of locked notes allowed (-1 = unlimited)
  final int maxLockedNotes;

  /// Whether real-time cloud sync is enabled (includes E2EE)
  final bool realtimeCloudSync;

  /// Whether the user can export notes (available to all)
  final bool canExport;

  const Entitlements({
    required this.maxLockedNotes,
    required this.realtimeCloudSync,
    required this.canExport,
  });

  /// Free tier entitlements
  static const Entitlements free = Entitlements(
    maxLockedNotes: 5,
    realtimeCloudSync: false,
    canExport: true,
  );

  /// Pro tier entitlements
  static const Entitlements pro = Entitlements(
    maxLockedNotes: -1, // Unlimited
    realtimeCloudSync: true,
    canExport: true,
  );

  /// Get entitlements for a given plan
  static Entitlements forPlan(UserPlan plan) {
    switch (plan) {
      case UserPlan.free:
        return free;
      case UserPlan.pro:
        return pro;
    }
  }

  /// Check if locked notes limit is reached
  bool hasReachedLockedNotesLimit(int currentLockedNotes) {
    if (maxLockedNotes == -1) return false;
    return currentLockedNotes >= maxLockedNotes;
  }

  /// Whether user has unlimited locked notes
  bool get hasUnlimitedLockedNotes => maxLockedNotes == -1;

  /// Copy with modifications (useful for testing or overrides)
  Entitlements copyWith({
    int? maxLockedNotes,
    bool? realtimeCloudSync,
    bool? canExport,
  }) {
    return Entitlements(
      maxLockedNotes: maxLockedNotes ?? this.maxLockedNotes,
      realtimeCloudSync: realtimeCloudSync ?? this.realtimeCloudSync,
      canExport: canExport ?? this.canExport,
    );
  }

  @override
  String toString() {
    return 'Entitlements(lockedNotes: $maxLockedNotes, realtimeCloudSync: $realtimeCloudSync)';
  }
}
