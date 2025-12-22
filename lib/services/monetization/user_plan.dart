/// User subscription plans for Better Keep Notes
///
/// This is the single source of truth for all plan definitions.
/// - FREE: Basic functionality, local-first
/// - PRO: Cloud sync, unlimited features
enum UserPlan {
  /// Free tier - local-first with limited cloud features
  free,

  /// Pro tier - full cloud sync and premium features
  pro;

  /// Display name for UI
  String get displayName {
    switch (this) {
      case UserPlan.free:
        return 'Free';
      case UserPlan.pro:
        return 'Pro';
    }
  }

  /// Whether this plan uses the hosted backend
  bool get usesHostedBackend => true;

  /// Whether this is a paid plan
  bool get isPaid {
    switch (this) {
      case UserPlan.free:
        return false;
      case UserPlan.pro:
        return true;
    }
  }

  /// Parse from string (e.g., from Firebase)
  static UserPlan fromString(String? value) {
    switch (value?.toLowerCase()) {
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
      case UserPlan.pro:
        return 'pro';
    }
  }
}
