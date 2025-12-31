import 'dart:async';
import 'dart:convert';

import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/services/auth/auth_service.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:better_keep/services/monetization/entitlements.dart';
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:better_keep/services/monetization/subscription_status.dart';
import 'package:better_keep/services/monetization/user_plan.dart';
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

  /// Firestore listener subscription
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _subscriptionListener;

  /// Auth state listener subscription
  StreamSubscription<User?>? _authStateSubscription;

  /// One-time timer for exact expiry moment
  Timer? _exactExpiryTimer;

  /// Last time we validated with backend (rate limiting)
  DateTime? _lastBackendValidation;

  /// Minimum time between backend validations (5 minutes)
  static const Duration _backendValidationCooldown = Duration(minutes: 5);

  // Keys for local storage
  static const String _cacheKey = 'subscription_cache';

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
      // Load cached subscription
      await _loadCachedSubscription();

      // If user is logged in, start listening for subscription changes
      final user = AuthService.currentUser;
      if (user != null) {
        await _startSubscriptionListener(user.uid);

        // Validate subscription with backend (async, don't block init)
        // This catches cases where webhook failed to update status
        _validateSubscriptionWithBackend();
      }

      // Listen for auth changes to start/stop subscription listener
      // But defer starting the listener if we're in the middle of sign-in
      // to avoid Firestore connection conflicts
      _authStateSubscription = FirebaseAuth.instance.authStateChanges().listen((
        user,
      ) {
        if (user != null) {
          // If we're in the middle of sign-in, defer starting the listener
          // _completeSignIn will handle this after auth is fully complete
          if (AuthService.isVerifying.value) {
            AppLogger.log(
              'PlanService: Sign-in in progress, deferring subscription listener',
            );
            return;
          }
          _startSubscriptionListener(user.uid);
          // Validate when user signs in
          _validateSubscriptionWithBackend();
        } else {
          _stopSubscriptionListener();
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

      if (!result.hasSubscription) {
        // Backend says no subscription - user's subscription was cancelled/expired
        // The backend already deleted the Firestore doc, which will trigger
        // our listener to update. But let's also clear cache immediately.
        AppLogger.log(
          'PlanService: Backend reports no active subscription, clearing local state',
        );
        _setSubscription(SubscriptionStatus.free);
        await _cacheSubscription(SubscriptionStatus.free);
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

  /// Load subscription from local cache
  Future<void> _loadCachedSubscription() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString(_cacheKey);

      if (cachedJson != null) {
        final cached = json.decode(cachedJson) as Map<String, dynamic>;
        final status = SubscriptionStatus.fromFirestore(cached);
        _setSubscription(status);
        AppLogger.log(
          'PlanService: Loaded cached subscription: ${status.plan.displayName}',
        );
      }
    } catch (e) {
      AppLogger.error('PlanService: Error loading cached subscription', e);
    }
  }

  /// Save subscription to local cache
  Future<void> _cacheSubscription(SubscriptionStatus status) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(status.toFirestore());
      await prefs.setString(_cacheKey, json);
    } catch (e) {
      AppLogger.error('PlanService: Error caching subscription', e);
    }
  }

  /// Start subscription listener for the current user.
  /// Call this after sign-in is complete to avoid Firestore connection conflicts.
  Future<void> startSubscriptionListener() async {
    final user = AuthService.currentUser;
    if (user != null) {
      await _startSubscriptionListener(user.uid);
      _validateSubscriptionWithBackend();
    }
  }

  /// Start listening for subscription changes from Firebase
  Future<void> _startSubscriptionListener(String uid) async {
    _stopSubscriptionListener();

    try {
      final db = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: DefaultFirebaseOptions.databaseId,
      );
      final docRef = db
          .collection('users')
          .doc(uid)
          .collection('subscription')
          .doc('status');

      AppLogger.log(
        'PlanService: Fetching subscription for user $uid from database: ${DefaultFirebaseOptions.databaseId}',
      );

      // First, fetch from server to ensure fresh data (bypasses cache)
      // This is important for web page refresh to get the latest state
      try {
        final serverSnapshot = await docRef.get(
          const GetOptions(source: Source.server),
        );
        AppLogger.log(
          'PlanService: Server snapshot exists: ${serverSnapshot.exists}, data: ${serverSnapshot.data()}',
        );
        if (serverSnapshot.exists) {
          final status = SubscriptionStatus.fromFirestore(
            serverSnapshot.data(),
          );
          _setSubscription(status);
          _cacheSubscription(status);
          AppLogger.log(
            'PlanService: Initial server fetch: ${status.plan.displayName}',
          );
        } else {
          _setSubscription(SubscriptionStatus.free);
          _cacheSubscription(SubscriptionStatus.free);
          AppLogger.log('PlanService: Initial server fetch: Free (no doc)');
        }
      } catch (e) {
        AppLogger.error(
          'PlanService: Error fetching initial subscription from server',
          e,
        );
        // Fall back to cache if server fetch fails
      }

      // Then start listening for real-time updates
      _subscriptionListener = docRef.snapshots().listen(
        (snapshot) {
          if (snapshot.exists) {
            final status = SubscriptionStatus.fromFirestore(snapshot.data());
            _setSubscription(status);
            _cacheSubscription(status);
            AppLogger.log(
              'PlanService: Subscription updated: ${status.plan.displayName}',
            );
          } else {
            // No subscription document = free tier
            _setSubscription(SubscriptionStatus.free);
            _cacheSubscription(SubscriptionStatus.free);
          }
        },
        onError: (e) {
          AppLogger.error('PlanService: Error listening to subscription', e);
          // Keep using cached/current subscription on error
        },
      );
    } catch (e) {
      AppLogger.error('PlanService: Error starting subscription listener', e);
    }
  }

  /// Stop listening for subscription changes
  void _stopSubscriptionListener() {
    _subscriptionListener?.cancel();
    _subscriptionListener = null;
  }

  /// Set the subscription and update entitlements
  void _setSubscription(SubscriptionStatus status) {
    final oldPlan = _subscriptionStatus.value.effectivePlan;
    final newPlan = status.effectivePlan;

    _subscriptionStatus.value = status;
    _entitlements.value = Entitlements.forPlan(status.effectivePlan);

    // Reschedule exact expiry timer when subscription changes
    _scheduleExactExpiryTimer();

    // If plan changed, refresh the Firebase Auth token to get updated custom claims
    // Custom claims are set by Cloud Functions when subscription changes
    if (oldPlan != newPlan) {
      _refreshAuthTokenForUpdatedClaims();
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
    final user = AuthService.currentUser;
    if (user == null) {
      _setSubscription(SubscriptionStatus.free);
      return;
    }

    // First, do a local expiry check (no network call)
    _checkExpiryAndUpdateEntitlements();

    try {
      final db = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: DefaultFirebaseOptions.databaseId,
      );
      final docRef = db
          .collection('users')
          .doc(user.uid)
          .collection('subscription')
          .doc('status');

      // Bypass Firestore cache to get fresh data from server
      final snapshot = await docRef.get(
        const GetOptions(source: Source.server),
      );

      if (snapshot.exists) {
        final status = SubscriptionStatus.fromFirestore(snapshot.data());
        _setSubscription(status);
        await _cacheSubscription(status);

        // If user appears to have a paid subscription and validation requested,
        // verify with backend (catches cases where webhook failed)
        if (validateWithBackend && status.plan.isPaid) {
          _validateSubscriptionWithBackend();
        }
      } else {
        _setSubscription(SubscriptionStatus.free);
        await _cacheSubscription(SubscriptionStatus.free);
      }
    } catch (e) {
      AppLogger.error('PlanService: Error refreshing subscription', e);
      // Keep using cached subscription on error
    }
  }

  /// Force validate subscription with Google Play API
  /// Use this when user manually requests a refresh or for debugging
  /// This clears local cache and reloads from Firestore first
  Future<void> forceValidateSubscription() async {
    final user = AuthService.currentUser;
    if (user == null) {
      _setSubscription(SubscriptionStatus.free);
      return;
    }

    // Clear local cache first
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    AppLogger.log('PlanService: Cleared subscription cache for force refresh');

    // Reload from Firestore (bypass cache - fetch from server)
    try {
      final db = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: DefaultFirebaseOptions.databaseId,
      );
      final docRef = db
          .collection('users')
          .doc(user.uid)
          .collection('subscription')
          .doc('status');

      // Force fetch from server, not cache
      final snapshot = await docRef.get(
        const GetOptions(source: Source.server),
      );

      if (snapshot.exists) {
        final status = SubscriptionStatus.fromFirestore(snapshot.data());
        _setSubscription(status);
        await _cacheSubscription(status);
        AppLogger.log(
          'PlanService: Force refresh - found subscription: ${status.plan}',
        );

        // Validate with backend if user has paid subscription
        if (status.plan.isPaid) {
          await _validateSubscriptionWithBackend(force: true);
        }
      } else {
        _setSubscription(SubscriptionStatus.free);
        await _cacheSubscription(SubscriptionStatus.free);
        AppLogger.log(
          'PlanService: Force refresh - no subscription found, set to free',
        );
      }
    } catch (e) {
      AppLogger.error('PlanService: Error during force refresh', e);
      // On error, set to free to be safe
      _setSubscription(SubscriptionStatus.free);
    }
  }

  /// Cleanup resources
  void dispose() {
    _stopSubscriptionListener();
    _authStateSubscription?.cancel();
    _authStateSubscription = null;
    _exactExpiryTimer?.cancel();
    _exactExpiryTimer = null;
  }
}
