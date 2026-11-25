import 'package:better_keep/l10n/app_localizations.dart';

/// User subscription plans for Better Keep Notes
///
/// This is the single source of truth for all plan definitions.
/// - FREE: Basic functionality, local-first
/// - PRO: Cloud sync, unlimited features
enum UserPlan {
  /// Free tier - local-first with limited cloud features
  free,

  /// Automatic sync using the user's external storage.
  lite,

  /// Pro tier - full cloud sync and premium features
  pro;

  /// Display name for UI (non-localized, for internal use)
  String get displayName {
    switch (this) {
      case UserPlan.free:
        return 'Free';
      case UserPlan.lite:
        return 'Lite';
      case UserPlan.pro:
        return 'Pro';
    }
  }

  /// Localized display name for UI
  String localizedDisplayName(AppLocalizations l10n) {
    switch (this) {
      case UserPlan.free:
        return l10n.planFree;
      case UserPlan.lite:
        return l10n.lite;
      case UserPlan.pro:
        return l10n.planPro;
    }
  }

  /// Whether this plan uses the hosted backend
  bool get usesHostedBackend => true;

  /// Whether this is a paid plan
  bool get isPaid {
    switch (this) {
      case UserPlan.free:
        return false;
      case UserPlan.lite:
      case UserPlan.pro:
        return true;
    }
  }

  /// Parse from string (e.g., from Firebase)
  static UserPlan fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'lite':
        return UserPlan.lite;
      case 'pro':
        return UserPlan.pro;
      default:
        return UserPlan.free;
    }
  }

  /// Convert to string for storage
  String toStorageString() {
    switch (this) {
      case UserPlan.free:
        return 'free';
      case UserPlan.lite:
        return 'lite';
      case UserPlan.pro:
        return 'pro';
    }
  }
}
