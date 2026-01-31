import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/monetization/entitlements.dart';
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/monetization/user_plan.dart';
import 'package:flutter/material.dart';

/// Feature types that can be gated
///
/// Pro features:
/// - Unlimited locked notes
/// - Real-time cloud sync with E2EE
enum GatedFeature {
  /// Lock notes with PIN (limited for free users)
  lockNote,

  /// Real-time cloud sync with E2EE
  realtimeCloudSync,
}

/// Result of an entitlement check
class EntitlementResult {
  /// Whether the feature is allowed
  final bool allowed;

  /// Reason for denial (null if allowed)
  final String? denialReason;

  /// The feature that was checked
  final GatedFeature? feature;

  /// Current usage (for limit-based features)
  final int? currentUsage;

  /// Maximum allowed (for limit-based features)
  final int? maxAllowed;

  const EntitlementResult._({
    required this.allowed,
    this.denialReason,
    this.feature,
    this.currentUsage,
    this.maxAllowed,
  });

  /// Allowed result
  static const EntitlementResult success = EntitlementResult._(allowed: true);

  /// Create a denied result
  factory EntitlementResult.denied({
    required String reason,
    GatedFeature? feature,
    int? currentUsage,
    int? maxAllowed,
  }) {
    return EntitlementResult._(
      allowed: false,
      denialReason: reason,
      feature: feature,
      currentUsage: currentUsage,
      maxAllowed: maxAllowed,
    );
  }
}

/// Central entitlement guard for feature gating.
///
/// Use this class to check if features are allowed before performing actions.
/// This ensures consistent enforcement across the entire app.
class EntitlementGuard {
  /// Get the singleton PlanService instance
  static PlanService get _planService => PlanService.instance;

  /// Get current entitlements
  static Entitlements get _entitlements => _planService.entitlements;

  /// Get current plan
  static UserPlan get currentPlan => _planService.currentPlan;

  // ==================== FEATURE CHECKS ====================

  /// Check if user can lock a note (respects limit)
  static EntitlementResult canLockNote(
    int currentLockedNotes,
    AppLocalizations l10n,
  ) {
    if (!_entitlements.hasReachedLockedNotesLimit(currentLockedNotes)) {
      return EntitlementResult.success;
    }
    return EntitlementResult.denied(
      reason: l10n.lockedNotesLimitReached(_entitlements.maxLockedNotes),
      feature: GatedFeature.lockNote,
      currentUsage: currentLockedNotes,
      maxAllowed: _entitlements.maxLockedNotes,
    );
  }

  /// Check if real-time cloud sync is allowed
  static EntitlementResult canUseRealtimeCloudSync(AppLocalizations l10n) {
    if (_entitlements.realtimeCloudSync) {
      return EntitlementResult.success;
    }
    return EntitlementResult.denied(
      reason: l10n.realtimeCloudSyncRequiresPro,
      feature: GatedFeature.realtimeCloudSync,
    );
  }

  // ==================== CONVENIENCE METHODS ====================

  /// Check if a specific feature is available
  static bool isFeatureAvailable(GatedFeature feature) {
    switch (feature) {
      case GatedFeature.lockNote:
        return _entitlements.hasUnlimitedLockedNotes;
      case GatedFeature.realtimeCloudSync:
        return _entitlements.realtimeCloudSync;
    }
  }

  /// Get a user-friendly description of a feature
  static String getFeatureDescription(
    GatedFeature feature,
    AppLocalizations l10n,
  ) {
    switch (feature) {
      case GatedFeature.lockNote:
        return l10n.unlimitedLockedNotes;
      case GatedFeature.realtimeCloudSync:
        return l10n.realtimeCloudSync;
    }
  }

  /// Get all features available for a plan
  static List<GatedFeature> getFeaturesForPlan(UserPlan plan) {
    final entitlements = Entitlements.forPlan(plan);
    final features = <GatedFeature>[];

    if (entitlements.hasUnlimitedLockedNotes) {
      features.add(GatedFeature.lockNote);
    }
    if (entitlements.realtimeCloudSync) {
      features.add(GatedFeature.realtimeCloudSync);
    }

    return features;
  }

  /// Get features exclusive to Pro plan
  static List<GatedFeature> get proExclusiveFeatures {
    return [GatedFeature.lockNote, GatedFeature.realtimeCloudSync];
  }
}

/// Extension to easily check entitlements from BuildContext
extension EntitlementContext on BuildContext {
  /// Get the current user plan
  UserPlan get userPlan => EntitlementGuard.currentPlan;

  /// Check if user is on free plan
  bool get isFreePlan => userPlan == UserPlan.free;

  /// Check if user is on pro plan
  bool get isProPlan => userPlan == UserPlan.pro;

  /// Check if user has a paid plan
  bool get hasPaidPlan => userPlan.isPaid;
}
