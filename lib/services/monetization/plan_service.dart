import 'package:better_keep/services/cloud_read.dart';
import 'dart:async';
import 'dart:convert';

import 'package:better_keep/services/cloud_session_recovery.dart';

import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:better_keep/services/monetization/entitlements.dart';
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:better_keep/services/monetization/subscription_snapshot_resolver.dart';
import 'package:better_keep/services/monetization/subscription_status.dart';
import 'package:better_keep/services/monetization/user_plan.dart';
import 'package:better_keep/services/monetization/verified_entitlement_snapshot.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing user subscription and entitlements.
///
/// This is the central authority for:
/// - Resolving the current user's plan
/// - Caching subscription status locally
/// - Providing entitlements for feature gating
/// - Syncing subscription status with Firebase
class PlanService {
  PlanService._internal();

  static final PlanService _instance = PlanService._internal();
  static PlanService get instance => _instance;

  /// Current subscription status
  final ValueNotifier<SubscriptionStatus> _subscriptionStatus = ValueNotifier(
    SubscriptionStatus.free,
  );

  /// Current entitlements based on subscription
  final ValueNotifier<Entitlements> _entitlements = ValueNotifier(
    Entitlements.free,
  );

  /// Whether the service has been initialized
  bool _initialized = false;
  int _subscriptionGeneration = 0;
  Future<void>? _listenerStart;

  /// Firestore listener subscription
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _subscriptionListener;

  /// Auth state listener subscription
  StreamSubscription<User?>? _authStateSubscription;

  /// One-time timer for exact expiry moment
  Timer? _exactExpiryTimer;

  /// Debounces recovery when Firestore briefly regresses to trial/free.
  Timer? _reconciliationTimer;

  VerifiedEntitlementSnapshot? _verifiedEntitlement;
  String? _activeSubscriptionUid;

  /// Last time we validated with backend (rate limiting)
  DateTime? _lastBackendValidation;

  /// Minimum time between backend validations (5 minutes)
  static const Duration _backendValidationCooldown = Duration(minutes: 5);

  // Keys for local storage
  static String get _cacheKey =>
      FirebaseScopedPreferences.key('subscription_cache');

  static String _verifiedCacheKey(String uid) => FirebaseScopedPreferences.key(
    'subscription_verified_entitlement_v2_$uid',
  );

  /// Get current subscription status
  SubscriptionStatus get status => _subscriptionStatus.value;

  /// Get current entitlements
  Entitlements get entitlements => _entitlements.value;

  /// Get current effective plan (accounts for expiration)
  UserPlan get currentPlan => _subscriptionStatus.value.effectivePlan;

  /// Listenable for subscription status changes
  ValueListenable<SubscriptionStatus> get statusNotifier => _subscriptionStatus;

  /// Listenable for entitlement changes
  ValueListenable<Entitlements> get entitlementsNotifier => _entitlements;

  /// Whether the user is on the free plan
  bool get isFree => currentPlan == UserPlan.free;

  /// Whether the user is on a paid plan (Pro)
  bool get isPaid => currentPlan.isPaid;

  /// Initialize the service
  Future<void> init() async {
    if (_initialized) return;

    try {
      final user = AuthService.currentUser;
      final reviewAuthorization = ReviewAccess.authorizationFor(user);
      if (reviewAuthorization != null) {
        activateReviewSession(reviewAuthorization);
      } else {
        // Review sessions must never inherit an ordinary account's cached plan.
        await _loadCachedSubscription(uid: user?.uid);
      }

      // If an ordinary user is logged in, start listening for changes.
      if (user != null &&
          reviewAuthorization == null &&
          AuthService.canSyncCloud) {
        unawaited(
          _startSubscriptionListener(user.uid).catchError((
            Object error,
            StackTrace stack,
          ) {
            AppLogger.error(
              'Subscription listener initialization deferred',
              error,
              stack,
            );
          }),
        );

        // Validate subscription with backend (async, don't block init)
        // This catches cases where webhook failed to update status
        _validateSubscriptionWithBackend();
      }

      // Listen for auth changes to start/stop subscription listener
      // But defer starting the listener if we're in the middle of sign-in
      // to avoid Firestore connection conflicts
      _authStateSubscription = FirebaseBackend.auth.authStateChanges().listen((
        user,
      ) {
        if (user != null) {
          final reviewAuthorization = ReviewAccess.authorizationFor(user);
          if (reviewAuthorization != null) {
            activateReviewSession(reviewAuthorization);
            return;
          }
          // If we're in the middle of sign-in, defer starting the listener
          // _completeSignIn will handle this after auth is fully complete
          if (AuthService.isVerifying.value) {
            AppLogger.log(
              'PlanService: Sign-in in progress, deferring subscription listener',
            );
            return;
          }
          if (!AuthService.canSyncCloud) return;
          unawaited(
            _startSubscriptionListener(user.uid).catchError((
              Object error,
              StackTrace stack,
            ) {
              AppLogger.error('Subscription listener deferred', error, stack);
            }),
          );
          // Validate when user signs in
          _validateSubscriptionWithBackend();
        } else {
          _stopSubscriptionListener();
          _verifiedEntitlement = null;
          _activeSubscriptionUid = null;
          _setSubscription(SubscriptionStatus.free);
        }
      });

      // Start periodic expiry check (every 6 hours as fallback)
      // Also schedule exact expiry timer if subscription has an expiry date
      _startExpiryCheckTimer();

      _initialized = true;
      AppLogger.log(
        'PlanService: Initialized with plan: ${currentPlan.displayName}',
      );
    } catch (e) {
      AppLogger.error('PlanService: Error initializing', e);
      // Fallback to cached or free
      _initialized = true;
    }
  }

  /// Schedule exact expiry timer for precise subscription expiry detection
  void _startExpiryCheckTimer() {
    _scheduleExactExpiryTimer();
  }

  /// Schedule a one-time timer to fire exactly when subscription expires
  void _scheduleExactExpiryTimer() {
    _exactExpiryTimer?.cancel();

    final status = _subscriptionStatus.value;
    if (status.expiresAt == null || !status.isActive) return;

    final now = DateTime.now();
    final expiresAt = status.expiresAt!;
    final timeUntilExpiry = expiresAt.difference(now);

    // Only schedule if expiry is in the future and within reasonable time (30 days)
    if (timeUntilExpiry.isNegative || timeUntilExpiry.inDays > 30) {
      return;
    }

    AppLogger.log(
      'PlanService: Scheduling expiry check in ${timeUntilExpiry.inMinutes} minutes',
    );

    _exactExpiryTimer = Timer(timeUntilExpiry + const Duration(seconds: 1), () {
      AppLogger.log('PlanService: Subscription expiry timer fired');
      _checkExpiryAndUpdateEntitlements();
    });
  }

  /// Validate subscription with backend to catch cases where webhook failed
  /// This is called async and doesn't block the app
  /// Rate-limited to avoid excessive API calls
  Future<void> _validateSubscriptionWithBackend({bool force = false}) async {
    if (ReviewAccess.isAuthorizedSessionFor(AuthService.currentUser)) return;

    // Only validate if user appears to have a paid subscription
    if (!isPaid) return;

    // Rate limit: don't validate more than once per 5 minutes (unless forced)
    if (!force && _lastBackendValidation != null) {
      final timeSinceLastValidation = DateTime.now().difference(
        _lastBackendValidation!,
      );
      if (timeSinceLastValidation < _backendValidationCooldown) {
        AppLogger.log(
          'PlanService: Skipping backend validation (cooldown: '
          '${(_backendValidationCooldown - timeSinceLastValidation).inSeconds}s remaining)',
        );
        return;
      }
    }

    try {
      AppLogger.log('PlanService: Validating subscription with backend...');
      _lastBackendValidation = DateTime.now();

      final result = await SubscriptionService.instance
          .checkExistingSubscription();

      if (result.explicitlyTerminal) {
        AppLogger.log(
          'PlanService: Backend explicitly confirmed provider entitlement ended',
        );
      } else if (!result.contractValid) {
        AppLogger.log(
          'PlanService: Backend entitlement contract is incomplete; preserving local state',
        );
      } else if (result.isTrial) {
        AppLogger.log(
          'PlanService: Backend reports trial; preserving any active provider floor',
        );
      } else if (!result.hasSubscription) {
        AppLogger.log(
          'PlanService: No linked provider record found; preserving cached state',
        );
      } else {
        AppLogger.log('PlanService: Backend confirmed subscription is active');
      }
    } catch (e) {
      // Don't fail silently but don't crash either - we still have Firestore listener
      AppLogger.error(
        'PlanService: Error validating subscription with backend',
        e,
      );
    }
  }

  /// Check if subscription has expired and update entitlements accordingly
  void _checkExpiryAndUpdateEntitlements() {
    final status = _subscriptionStatus.value;
    final currentEffectivePlan = status.effectivePlan;
    final currentEntitlements = Entitlements.forPlan(currentEffectivePlan);

    // If entitlements have changed (e.g., subscription just expired), update them
    if (_entitlements.value != currentEntitlements) {
      AppLogger.log(
        'PlanService: Subscription expiry check - updating entitlements from '
        '${_entitlements.value} to $currentEntitlements',
      );
      _entitlements.value = currentEntitlements;

      // Also trigger a refresh from server to sync state
      if (AuthService.currentUser != null && status.isExpired) {
        refreshSubscription();
      }
    }
  }

  bool Function() _captureSession() {
    final accountCurrent = AuthService.captureSession();
    final generation = _subscriptionGeneration;
    return () => accountCurrent() && generation == _subscriptionGeneration;
  }

  /// Load subscription from local cache
  Future<void> _loadCachedSubscription({String? uid}) async {
    final current = _captureSession();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!current()) return;
      final cachedJson = prefs.getString(_cacheKey);

      if (cachedJson != null &&
          uid != null &&
          prefs.getString(FirebaseScopedPreferences.key('user_uid')) == uid &&
          AuthService.currentUser?.uid == uid) {
        final cached = json.decode(cachedJson) as Map<String, dynamic>;
        final status = SubscriptionStatus.fromFirestore(cached);
        _setSubscription(status);
        AppLogger.log(
          'PlanService: Loaded cached subscription: ${status.plan.displayName}',
        );
      }

      if (uid != null) {
        _activeSubscriptionUid = uid;
        await _loadVerifiedEntitlement(prefs, uid, isCurrent: current);
      }
    } catch (e) {
      AppLogger.error('PlanService: Error loading cached subscription', e);
    }
  }

  Future<void> _loadVerifiedEntitlement(
    SharedPreferences preferences,
    String uid, {
    bool Function()? isCurrent,
  }) async {
    if (!(isCurrent?.call() ?? true)) return;
    final encoded = preferences.getString(_verifiedCacheKey(uid));
    if (encoded == null) {
      _verifiedEntitlement = null;
      return;
    }

    try {
      final decoded = jsonDecode(encoded);
      final snapshot = decoded is Map
          ? VerifiedEntitlementSnapshot.fromJson(
              Map<String, dynamic>.from(decoded),
              expectedUid: uid,
            )
          : null;
      if (snapshot == null) {
        await preferences.remove(_verifiedCacheKey(uid));
        if (!(isCurrent?.call() ?? true)) return;
        _verifiedEntitlement = null;
        return;
      }

      _verifiedEntitlement = snapshot;
      _setSubscription(snapshot.status);
      await _cacheSubscription(snapshot.status, isCurrent: isCurrent);
      AppLogger.log(
        'PlanService: Restored UID-scoped verified ${snapshot.status.purchasePlatform} entitlement',
      );
    } catch (error) {
      if (!(isCurrent?.call() ?? true)) return;
      await preferences.remove(_verifiedCacheKey(uid));
      if (!(isCurrent?.call() ?? true)) return;
      _verifiedEntitlement = null;
      AppLogger.error(
        'PlanService: Rejected invalid verified entitlement cache',
        error,
      );
    }
  }

  /// Save subscription to local cache
  Future<void> _cacheSubscription(
    SubscriptionStatus status, {
    bool Function()? isCurrent,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(isCurrent?.call() ?? true)) return;
      final json = jsonEncode(status.toFirestore());
      await prefs.setString(_cacheKey, json);
    } catch (e) {
      AppLogger.error('PlanService: Error caching subscription', e);
    }
  }

  Future<void> _persistVerifiedEntitlement(
    VerifiedEntitlementSnapshot snapshot,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _verifiedCacheKey(snapshot.uid),
      jsonEncode(snapshot.toJson()),
    );
  }

  Future<void> _clearVerifiedEntitlement(String uid) async {
    if (_verifiedEntitlement?.uid == uid) _verifiedEntitlement = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_verifiedCacheKey(uid));
  }

  Future<void> _applyIncomingSubscription(
    SubscriptionStatus? incoming, {
    required String origin,
    bool explicitTerminal = false,
    bool Function()? isCurrent,
  }) async {
    if (!(isCurrent?.call() ?? true)) return;
    final uid = _activeSubscriptionUid;
    final verified = uid != null && _verifiedEntitlement?.uid == uid
        ? _verifiedEntitlement!.status
        : null;
    final resolution = resolveSubscriptionSnapshot(
      current: status,
      incoming: incoming,
      verified: verified,
      explicitTerminal: explicitTerminal,
    );

    _setSubscription(resolution.status);
    await _cacheSubscription(resolution.status, isCurrent: isCurrent);
    if (!(isCurrent?.call() ?? true)) return;

    if (!resolution.retainVerifiedSnapshot && uid != null) {
      await _clearVerifiedEntitlement(uid);
    }
    if (resolution.shouldReconcile) {
      AppLogger.log(
        'PlanService: Ignored regressive $origin subscription snapshot; scheduling reconciliation',
      );
      _scheduleProviderReconciliation();
    }
  }

  void _scheduleProviderReconciliation() {
    _reconciliationTimer?.cancel();
    _reconciliationTimer = Timer(const Duration(milliseconds: 750), () {
      unawaited(_validateSubscriptionWithBackend(force: true));
    });
  }

  /// Start subscription listener for the current user.
  /// Call this after sign-in is complete to avoid Firestore connection conflicts.
  Future<void> startSubscriptionListener() async {
    final user = AuthService.currentUser;
    if (user != null && !ReviewAccess.isAuthorizedSessionFor(user)) {
      await _startSubscriptionListener(user.uid);
      _validateSubscriptionWithBackend();
    }
  }

  /// Applies the review account's signed subscription claims locally.
  ///
  /// Review sessions intentionally avoid Firestore subscription listeners and
  /// the ordinary account cache, while still receiving paid UI entitlements.
  void activateReviewSession(ReviewAuthorization authorization) {
    _stopSubscriptionListener();

    if (authorization.hasActivePro()) {
      _setSubscription(
        SubscriptionStatus(
          plan: UserPlan.pro,
          expiresAt: authorization.planExpiresAt,
          purchasePlatform: 'review',
          willAutoRenew: false,
        ),
        refreshAuthToken: false,
      );
      AppLogger.log('PlanService: Activated signed review Pro entitlement');
      return;
    }

    _setSubscription(SubscriptionStatus.free, refreshAuthToken: false);
    AppLogger.error(
      'PlanService: Review authorization is missing an active Pro claim',
    );
  }

  /// Start listening for subscription changes from Firebase
  Future<void> _startSubscriptionListener(String uid) {
    if (_activeSubscriptionUid == uid && _subscriptionListener != null) {
      return Future.value();
    }
    if (_activeSubscriptionUid == uid && _listenerStart != null) {
      return _listenerStart!;
    }
    _stopSubscriptionListener();
    if (_activeSubscriptionUid != null && _activeSubscriptionUid != uid) {
      _verifiedEntitlement = null;
      _setSubscription(SubscriptionStatus.free);
    }
    _activeSubscriptionUid = uid;
    final generation = _subscriptionGeneration;
    final sessionCurrent = AuthService.captureSession();
    bool current() =>
        sessionCurrent() &&
        generation == _subscriptionGeneration &&
        _activeSubscriptionUid == uid;
    late final Future<void> operation;
    operation =
        (() async {
          final preferences = await SharedPreferences.getInstance();
          if (!current()) return;
          await _loadVerifiedEntitlement(preferences, uid, isCurrent: current);
          if (!current()) return;
          // The listener supplies both cache and server state without a blocking
          // first fetch, and cached misses cannot erase a verified entitlement.
          final reference = FirebaseBackend.firestore
              .collection('users')
              .doc(uid)
              .collection('subscription')
              .doc('status');
          _subscriptionListener = reference
              .snapshots(includeMetadataChanges: true)
              .listen(
                (snapshot) async {
                  if (!current() || snapshot.metadata.hasPendingWrites) return;
                  if (!snapshot.exists && snapshot.metadata.isFromCache) return;
                  try {
                    await _applyIncomingSubscription(
                      snapshot.exists
                          ? SubscriptionStatus.fromFirestore(snapshot.data())
                          : null,
                      origin: snapshot.metadata.isFromCache
                          ? 'cached Firestore'
                          : 'Firestore',
                      isCurrent: current,
                    );
                  } catch (error, stack) {
                    if (current()) {
                      AppLogger.error(
                        'Subscription update failed',
                        error,
                        stack,
                      );
                    }
                  }
                },
                onError: (Object error, StackTrace stack) {
                  if (!current()) return;
                  _stopSubscriptionListener();
                  if (isCloudConnectionFailure(error)) {
                    AuthService.cloudRecovery.connectionLost();
                  }
                  AppLogger.error(
                    'Subscription listener deferred',
                    error,
                    stack,
                  );
                },
              );
        })().whenComplete(() {
          if (identical(_listenerStart, operation)) _listenerStart = null;
        });
    _listenerStart = operation;
    return operation;
  }

  /// Stop listening for subscription changes
  void _stopSubscriptionListener() {
    _subscriptionGeneration++;
    _listenerStart = null;
    _subscriptionListener?.cancel();
    _subscriptionListener = null;
    _reconciliationTimer?.cancel();
    _reconciliationTimer = null;
  }

  /// Set the subscription and update entitlements
  void _setSubscription(
    SubscriptionStatus status, {
    bool refreshAuthToken = true,
  }) {
    final oldPlan = _subscriptionStatus.value.effectivePlan;
    final newPlan = status.effectivePlan;

    _subscriptionStatus.value = status;
    _entitlements.value = Entitlements.forPlan(status.effectivePlan);

    // Reschedule exact expiry timer when subscription changes
    _scheduleExactExpiryTimer();

    // If plan changed, refresh the Firebase Auth token to get updated custom claims
    // Custom claims are set by Cloud Functions when subscription changes
    if (refreshAuthToken && oldPlan != newPlan) {
      _refreshAuthTokenForUpdatedClaims();
    }
  }

  Future<void> _refreshReviewSession(User user) async {
    try {
      final authorized = await ReviewAccess.refreshAuthorization(user);
      final authorization = ReviewAccess.authorizationFor(user);
      if (authorized && authorization != null) {
        activateReviewSession(authorization);
      } else {
        _setSubscription(SubscriptionStatus.free, refreshAuthToken: false);
        AppLogger.error('PlanService: Review authorization is no longer valid');
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'PlanService: Could not refresh signed review entitlement',
        error,
        stackTrace,
      );
    }
  }

  /// Refresh Firebase Auth token to pick up updated custom claims.
  ///
  /// When the subscription status changes on the server, Cloud Functions update
  /// the user's custom claims. The client needs to refresh its ID token to see
  /// these updated claims, which are then used by Firestore/Storage security rules.
  Future<void> _refreshAuthTokenForUpdatedClaims() async {
    try {
      final user = AuthService.currentUser;
      if (user == null) return;

      // Force refresh the ID token to get updated custom claims
      await user.getIdToken(true);
      AppLogger.log(
        'PlanService: Refreshed auth token for updated subscription claims',
      );
    } catch (e) {
      AppLogger.error('PlanService: Error refreshing auth token', e);
      // Non-fatal - the token will eventually refresh on its own
    }
  }

  /// Force refresh subscription status from Firebase
  /// Also validates with Google Play if user appears to have a subscription
  Future<void> refreshSubscription({bool validateWithBackend = false}) async {
    final current = _captureSession();
    final user = AuthService.currentUser;
    if (user == null) {
      _setSubscription(SubscriptionStatus.free);
      return;
    }

    if (ReviewAccess.isAuthorizedSessionFor(user)) {
      await _refreshReviewSession(user);
      return;
    }

    // First, do a local expiry check (no network call)
    _checkExpiryAndUpdateEntitlements();

    try {
      final db = FirebaseBackend.firestore;
      final docRef = db
          .collection('users')
          .doc(user.uid)
          .collection('subscription')
          .doc('status');

      // Bypass Firestore cache to get fresh data from server
      final snapshot = await readCloudDocument(docRef, isCurrent: current);

      if (snapshot.exists) {
        final status = SubscriptionStatus.fromFirestore(snapshot.data());
        await _applyIncomingSubscription(
          status,
          origin: 'server refresh',
          isCurrent: current,
        );

        // If user appears to have a paid subscription and validation requested,
        // verify with backend (catches cases where webhook failed)
        if (validateWithBackend && status.plan.isPaid) {
          _validateSubscriptionWithBackend();
        }
      } else {
        await _applyIncomingSubscription(
          null,
          origin: 'server refresh missing',
          isCurrent: current,
        );
      }
    } catch (e) {
      AppLogger.error('PlanService: Error refreshing subscription', e);
      // Keep using cached subscription on error
    }
  }

  /// Applies a paid entitlement returned by authenticated purchase verification.
  ///
  /// Firestore and custom claims remain authoritative. This is a local fallback
  /// for the short window where the canonical status read still returns trial.
  Future<bool> applyVerifiedEntitlement(Map<String, dynamic>? data) async {
    final current = _captureSession();
    final user = AuthService.currentUser;
    final snapshot = user == null
        ? null
        : VerifiedEntitlementSnapshot.fromBackend(uid: user.uid, data: data);
    if (snapshot == null) {
      AppLogger.log(
        'PlanService: Rejected incomplete verified entitlement payload',
      );
      return false;
    }

    _activeSubscriptionUid = user!.uid;
    _verifiedEntitlement = snapshot;
    await _persistVerifiedEntitlement(snapshot);
    if (!current()) return false;
    _setSubscription(snapshot.status);
    await _cacheSubscription(snapshot.status, isCurrent: current);
    AppLogger.log(
      'PlanService: Applied verified ${snapshot.status.purchasePlatform} entitlement',
    );
    return true;
  }

  /// Applies only a versioned backend terminal provider result.
  Future<void> applyExplicitTerminalEntitlement() async {
    final user = AuthService.currentUser;
    if (user == null) return;
    _activeSubscriptionUid = user.uid;
    await _applyIncomingSubscription(
      SubscriptionStatus.free,
      origin: 'terminal backend',
      explicitTerminal: true,
    );
  }

  Future<void> applyOwnershipConflict({required String source}) async {
    final current = _captureSession();
    final user = AuthService.currentUser;
    if (user == null) return;
    await _clearVerifiedEntitlement(user.uid);
    if (!current()) return;
    if (status.purchasePlatform == source) {
      await _applyIncomingSubscription(
        SubscriptionStatus.free,
        origin: 'provider ownership conflict',
        explicitTerminal: true,
      );
    }
  }

  /// Force validate subscription with Google Play API
  /// Use this when user manually requests a refresh or for debugging
  /// Existing access is retained if backend/Firestore transport is unavailable.
  Future<void> forceValidateSubscription() async {
    final current = _captureSession();
    final user = AuthService.currentUser;
    if (user == null) {
      _setSubscription(SubscriptionStatus.free);
      return;
    }

    if (ReviewAccess.isAuthorizedSessionFor(user)) {
      await _refreshReviewSession(user);
      return;
    }

    try {
      // Backend/provider records are checked before Firestore so a stale trial
      // document cannot win the race during manual recovery.
      final backend = await SubscriptionService.instance
          .checkExistingSubscription();
      if (!current()) return;
      if (backend.hasSubscription && backend.localEntitlementActive) {
        AppLogger.log(
          'PlanService: Force refresh confirmed active provider entitlement',
        );
        return;
      }
      if (backend.explicitlyTerminal) {
        AppLogger.log(
          'PlanService: Force refresh confirmed terminal provider state',
        );
        return;
      }

      final db = FirebaseBackend.firestore;
      final docRef = db
          .collection('users')
          .doc(user.uid)
          .collection('subscription')
          .doc('status');

      // Force fetch from server, not cache
      final snapshot = await readCloudDocument(docRef, isCurrent: current);

      if (snapshot.exists) {
        final status = SubscriptionStatus.fromFirestore(snapshot.data());
        await _applyIncomingSubscription(
          status,
          origin: 'force refresh',
          isCurrent: current,
        );
        AppLogger.log(
          'PlanService: Force refresh - found subscription: ${status.plan}',
        );
      } else {
        await _applyIncomingSubscription(
          null,
          origin: 'force refresh missing',
          isCurrent: current,
        );
        AppLogger.log(
          'PlanService: Force refresh found no canonical subscription document',
        );
      }
    } catch (e) {
      AppLogger.error('PlanService: Error during force refresh', e);
      // Preserve the current verified/cached entitlement on DNS, timeout,
      // App Check, or Firestore transport failures.
    }
  }

  /// Cleanup resources
  void dispose() {
    _stopSubscriptionListener();
    _authStateSubscription?.cancel();
    _authStateSubscription = null;
    _exactExpiryTimer?.cancel();
    _exactExpiryTimer = null;
    _reconciliationTimer?.cancel();
    _reconciliationTimer = null;
    _verifiedEntitlement = null;
    _activeSubscriptionUid = null;
    _subscriptionStatus.value = SubscriptionStatus.free;
    _entitlements.value = Entitlements.free;
    _lastBackendValidation = null;
    _initialized = false;
  }
}
