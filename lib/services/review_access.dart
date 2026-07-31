import 'package:better_keep/config.dart' show demoAccountEmail;
import 'package:firebase_auth/firebase_auth.dart';

class ReviewAuthorizationException implements Exception {
  const ReviewAuthorizationException([
    this.message = 'The managed review account is not configured correctly.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class ReviewCloudMutationBlocked implements Exception {
  const ReviewCloudMutationBlocked(this.operation);

  final String operation;

  @override
  String toString() =>
      '$operation is unavailable for the managed review account.';
}

enum ReviewCapability {
  cloudMutation,
  cloudLinkSharing,
  accountManagement,
  accountRecovery,
  localNotes,
  localSharing,
}

class ReviewAuthorization {
  ReviewAuthorization.fromClaims({
    required this.uid,
    required Map<String, dynamic> claims,
  }) : plan = claims['plan'] is String ? claims['plan'] as String : null,
       planExpiresAt = _parsePlanExpiration(claims['planExpiresAt']);

  final String uid;
  final String? plan;
  final DateTime? planExpiresAt;

  bool hasActivePro({DateTime? at}) {
    final expiresAt = planExpiresAt;
    return plan == 'pro' &&
        expiresAt != null &&
        expiresAt.isAfter(at ?? DateTime.now());
  }

  static DateTime? _parsePlanExpiration(Object? value) {
    if (value is! num || !value.isFinite) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    } on RangeError {
      return null;
    }
  }
}

/// Authorizes the isolated Google Play review session.
///
/// The email is only an identity constraint. The actual authorization comes
/// from the Firebase-signed [claimName] custom claim.
class ReviewAccess {
  ReviewAccess._();

  static const String claimName = 'appReview';

  static ReviewAuthorization? _authorization;

  static bool _isReviewIdentity(String? email) =>
      email?.trim().toLowerCase() == demoAccountEmail.toLowerCase();

  static bool isReviewIdentity(User? user) => _isReviewIdentity(user?.email);

  static bool isCloudMutationBlockedFor(User? user) =>
      isReviewIdentity(user) || isAuthorizedSessionFor(user);

  static bool allows(User? user, ReviewCapability capability) {
    switch (capability) {
      case ReviewCapability.localNotes:
      case ReviewCapability.localSharing:
        return true;
      case ReviewCapability.cloudMutation:
      case ReviewCapability.cloudLinkSharing:
      case ReviewCapability.accountManagement:
      case ReviewCapability.accountRecovery:
        return !isCloudMutationBlockedFor(user);
    }
  }

  static void ensureCloudMutationAllowed(
    User? user, {
    required String operation,
  }) {
    if (!allows(user, ReviewCapability.cloudMutation)) {
      throw ReviewCloudMutationBlocked(operation);
    }
  }

  static void requireAuthorizedReviewIdentity(User user, bool authorized) {
    if (isReviewIdentity(user) && !authorized) {
      throw const ReviewAuthorizationException();
    }
  }

  /// Returns whether the authenticated identity and signed token claims match
  /// the dedicated review account.
  static bool hasRequiredAuthorization({
    required String? email,
    required Map<String, dynamic>? claims,
  }) {
    final tokenEmail = claims?['email'];

    return _isReviewIdentity(email) &&
        tokenEmail is String &&
        _isReviewIdentity(tokenEmail) &&
        claims?[claimName] == true;
  }

  /// Authorizes [user] from its current signed token.
  ///
  /// Firebase returns a valid cached token when available and refreshes it only
  /// when expired. Non-review identities are rejected without loading a token.
  static Future<bool> authorize(User user) =>
      _authorize(user, forceRefresh: false);

  /// Forces a fresh signed token before updating review authorization.
  static Future<bool> refreshAuthorization(User user) =>
      _authorize(user, forceRefresh: true);

  static Future<bool> _authorize(
    User user, {
    required bool forceRefresh,
  }) async {
    if (!_isReviewIdentity(user.email)) {
      _authorization = null;
      return false;
    }

    // Do not clear an already verified authorization until signed claims are
    // received. A transient token failure must remain retryable.
    final token = await user.getIdTokenResult(forceRefresh);
    final authorized = hasRequiredAuthorization(
      email: user.email,
      claims: token.claims,
    );
    if (authorized) {
      _authorization = ReviewAuthorization.fromClaims(
        uid: user.uid,
        claims: token.claims ?? const {},
      );
    } else {
      _authorization = null;
    }
    return authorized;
  }

  static ReviewAuthorization? authorizationFor(User? user) {
    final authorization = _authorization;
    if (user == null ||
        authorization == null ||
        authorization.uid != user.uid ||
        user.email?.trim().toLowerCase() != demoAccountEmail.toLowerCase()) {
      return null;
    }
    return authorization;
  }

  /// Synchronous check used after [authorize] has verified the signed token.
  static bool isAuthorizedSessionFor(User? user) {
    return authorizationFor(user) != null;
  }

  static void clear() {
    _authorization = null;
  }
}
