import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:better_keep/services/auth_service.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/monetization/user_plan.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'razorpay_web.dart'
    if (dart.library.io) 'razorpay_stub.dart'
    as razorpay_platform;

/// Razorpay plan IDs (configured in Razorpay Dashboard)
class RazorpayPlanIds {
  /// Monthly subscription plan ID
  static const String proMonthly = 'plan_pro_monthly';

  /// Yearly subscription plan ID
  static const String proYearly = 'plan_pro_yearly';
}

/// Result of Razorpay payment
class RazorpayPaymentResult {
  final bool success;
  final bool cancelled;
  final String? paymentId;
  final String? subscriptionId;
  final String? orderId;
  final String? signature;
  final String? error;

  RazorpayPaymentResult({
    required this.success,
    this.cancelled = false,
    this.paymentId,
    this.subscriptionId,
    this.orderId,
    this.signature,
    this.error,
  });

  factory RazorpayPaymentResult.cancelled() {
    return RazorpayPaymentResult(
      success: false,
      cancelled: true,
      error: 'Payment cancelled by user',
    );
  }

  factory RazorpayPaymentResult.failed(String error) {
    return RazorpayPaymentResult(success: false, error: error);
  }
}

/// Handles Razorpay payments for web and desktop platforms.
///
/// - Web: Uses Razorpay Checkout.js via JS interop
/// - Desktop (Windows/Linux): Uses WebView to load Razorpay checkout
///
/// Uses Razorpay Subscriptions API for recurring payments.
class RazorpayService {
  RazorpayService._internal();

  static final RazorpayService _instance = RazorpayService._internal();
  static RazorpayService get instance => _instance;

  // Loading state
  final ValueNotifier<bool> isLoading = ValueNotifier(false);

  // Last error message
  String? _lastError;
  String? get lastError => _lastError;
  void clearLastError() => _lastError = null;

  /// Check if Razorpay is available on this platform
  bool get isAvailable {
    if (kIsWeb) return true;
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) return true;
    return false;
  }

  /// Get the Razorpay Test Key ID from environment
  String get _testKeyId {
    const testKeyId = String.fromEnvironment(
      'PG_TEST_KEY_ID',
      defaultValue: '',
    );
    return testKeyId;
  }

  /// Get the Razorpay Key ID from environment
  String get _keyId {
    const keyId = String.fromEnvironment('PG_KEY_ID', defaultValue: '');
    return keyId;
  }

  /// Get the appropriate key - test key in debug mode (if provided), else server key
  String _getCheckoutKey(String serverKeyId) {
    if (kDebugMode && _testKeyId.isNotEmpty) {
      AppLogger.log('RazorpayService: Using TEST key (debug mode)');
      return _testKeyId;
    }
    return serverKeyId;
  }

  /// Check if running on desktop (Windows/Linux) where httpsCallable doesn't work
  bool get _isDesktop => !kIsWeb && (Platform.isWindows || Platform.isLinux);

  /// Firebase project ID for constructing Cloud Function URLs
  String get _projectId {
    const projectId = String.fromEnvironment(
      'WEB_PROJECT_ID',
      defaultValue: 'better-keep-notes',
    );
    return projectId;
  }

  /// Get the Cloud Functions base URL (emulator in debug mode, production otherwise)
  String get _functionsBaseUrl {
    if (kDebugMode) {
      // Use localhost for emulator in debug mode
      return 'http://localhost:5001/$_projectId/us-central1';
    }
    return 'https://us-central1-$_projectId.cloudfunctions.net';
  }

  /// Call a Firebase Cloud Function via direct HTTP request.
  /// This is needed for desktop platforms (Windows/Linux) where
  /// the httpsCallable platform channel doesn't work.
  Future<Map<String, dynamic>> _callCloudFunction(
    String functionName, [
    Map<String, dynamic>? data,
  ]) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('User not authenticated');
    }

    // Get the user's ID token for authentication
    final idToken = await user.getIdToken();

    // Cloud Function URL - uses emulator or production based on config
    final url = Uri.parse('$_functionsBaseUrl/$functionName');

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $idToken',
      },
      body: jsonEncode({'data': data ?? {}}),
    );

    if (response.statusCode != 200) {
      AppLogger.error(
        'RazorpayService: Cloud function error - status: ${response.statusCode}, body: ${response.body}',
      );
      throw Exception('Cloud function call failed: ${response.statusCode}');
    }

    final responseData = jsonDecode(response.body) as Map<String, dynamic>;
    // Cloud Functions wrap the response in a 'result' key
    if (responseData.containsKey('result')) {
      return Map<String, dynamic>.from(responseData['result'] as Map);
    }
    return responseData;
  }

  /// Purchase a Pro subscription via Razorpay
  ///
  /// Creates a subscription in Razorpay and opens checkout.
  /// On successful payment, verifies with backend and activates subscription.
  Future<RazorpayPaymentResult> purchaseSubscription({
    required bool yearly,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) {
      return RazorpayPaymentResult.failed('Please sign in first');
    }

    try {
      isLoading.value = true;
      _lastError = null;

      // Step 1: Create subscription on backend
      AppLogger.log('RazorpayService: Creating subscription (yearly: $yearly)');

      final Map<String, dynamic> createData;
      if (_isDesktop) {
        createData = await _callCloudFunction('createRazorpaySubscription', {
          'yearly': yearly,
        });
      } else {
        final functions = FirebaseFunctions.instance;
        final createResult = await functions
            .httpsCallable('createRazorpaySubscription')
            .call({'yearly': yearly});
        createData = Map<String, dynamic>.from(createResult.data as Map);
      }

      final subscriptionId = createData['subscriptionId'] as String?;
      if (subscriptionId == null) {
        return RazorpayPaymentResult.failed('Failed to create subscription');
      }

      final planName = createData['name'] as String? ?? 'Pro Subscription';
      // Use test key in debug mode, live key in release
      final serverKeyId = createData['keyId'] as String? ?? _keyId;
      final keyId = _getCheckoutKey(serverKeyId);

      AppLogger.log('RazorpayService: Subscription created: $subscriptionId');

      // Step 2: Open Razorpay checkout
      final paymentResult = await _openSubscriptionCheckout(
        keyId: keyId,
        subscriptionId: subscriptionId,
        description: planName,
        email: user.email ?? '',
      );

      if (!paymentResult.success) {
        if (paymentResult.cancelled) {
          return RazorpayPaymentResult.cancelled();
        }
        return paymentResult;
      }

      AppLogger.log('RazorpayService: Payment successful, verifying...');

      // Step 3: Verify payment with backend
      final Map<String, dynamic> verifyData;
      if (_isDesktop) {
        verifyData = await _callCloudFunction('verifyRazorpaySubscription', {
          'paymentId': paymentResult.paymentId,
          'subscriptionId': paymentResult.subscriptionId,
          'signature': paymentResult.signature,
        });
      } else {
        final functions = FirebaseFunctions.instance;
        final verifyResult = await functions
            .httpsCallable('verifyRazorpaySubscription')
            .call({
              'paymentId': paymentResult.paymentId,
              'subscriptionId': paymentResult.subscriptionId,
              'signature': paymentResult.signature,
            });
        verifyData = Map<String, dynamic>.from(verifyResult.data as Map);
      }

      if (verifyData['success'] != true) {
        final error = verifyData['error'] as String? ?? 'Verification failed';
        return RazorpayPaymentResult.failed(error);
      }

      AppLogger.log('RazorpayService: Subscription verified and activated');

      // Force refresh local subscription status (bypass cache)
      await PlanService.instance.forceValidateSubscription();

      return RazorpayPaymentResult(
        success: true,
        paymentId: paymentResult.paymentId,
        subscriptionId: paymentResult.subscriptionId,
        signature: paymentResult.signature,
      );
    } on FirebaseFunctionsException catch (e) {
      AppLogger.error(
        'RazorpayService: Firebase function error - code: ${e.code}, message: ${e.message}, details: ${e.details}',
        e,
      );
      // Extract the actual error message
      final errorMessage = e.message ?? 'Payment failed';
      _lastError = errorMessage;
      return RazorpayPaymentResult.failed(errorMessage);
    } catch (e) {
      AppLogger.error('RazorpayService: Error', e);
      _lastError = e.toString();
      return RazorpayPaymentResult.failed(_lastError!);
    } finally {
      isLoading.value = false;
    }
  }

  /// Open Razorpay checkout for subscription
  Future<RazorpayPaymentResult> _openSubscriptionCheckout({
    required String keyId,
    required String subscriptionId,
    required String description,
    required String email,
  }) async {
    if (kIsWeb) {
      return razorpay_platform.openSubscriptionCheckout(
        keyId: keyId,
        subscriptionId: subscriptionId,
        name: 'Better Keep',
        description: description,
        email: email,
      );
    } else if (Platform.isWindows || Platform.isLinux) {
      return _openDesktopSubscriptionCheckout(
        keyId: keyId,
        subscriptionId: subscriptionId,
        description: description,
        email: email,
      );
    }

    return RazorpayPaymentResult.failed('Platform not supported');
  }

  /// Open checkout in WebView for desktop (Windows/Linux)
  Future<RazorpayPaymentResult> _openDesktopSubscriptionCheckout({
    required String keyId,
    required String subscriptionId,
    required String description,
    required String email,
  }) async {
    // Import and use the desktop webview implementation
    try {
      final result = await razorpay_platform.openDesktopSubscriptionCheckout(
        keyId: keyId,
        subscriptionId: subscriptionId,
        name: 'Better Keep',
        description: description,
        email: email,
      );
      return result;
    } catch (e) {
      AppLogger.error('RazorpayService: Desktop checkout error', e);
      return RazorpayPaymentResult.failed('Failed to open payment window: $e');
    }
  }

  /// Cancel subscription
  ///
  /// For Razorpay subscriptions, cancellation is handled via webhook
  /// when user cancels through Razorpay dashboard or we call cancel API.
  Future<bool> cancelSubscription() async {
    final user = AuthService.currentUser;
    if (user == null) return false;

    try {
      isLoading.value = true;

      final Map<String, dynamic> data;
      if (_isDesktop) {
        // Use direct HTTP call on desktop platforms
        data = await _callCloudFunction('cancelRazorpaySubscription');
      } else {
        final functions = FirebaseFunctions.instance;
        final result = await functions
            .httpsCallable('cancelRazorpaySubscription')
            .call({});
        data = Map<String, dynamic>.from(result.data as Map);
      }

      if (data['success'] == true) {
        await PlanService.instance.refreshSubscription();
        return true;
      }

      _lastError = data['error'] as String? ?? 'Failed to cancel subscription';
      return false;
    } catch (e) {
      AppLogger.error('RazorpayService: Cancel error', e);
      _lastError = 'Failed to cancel subscription';
      return false;
    } finally {
      isLoading.value = false;
    }
  }

  /// Resume a cancelled subscription
  Future<bool> resumeSubscription() async {
    final user = AuthService.currentUser;
    if (user == null) return false;

    try {
      isLoading.value = true;

      final Map<String, dynamic> data;
      if (_isDesktop) {
        // Use direct HTTP call on desktop platforms
        data = await _callCloudFunction('resumeRazorpaySubscription');
      } else {
        final functions = FirebaseFunctions.instance;
        final result = await functions
            .httpsCallable('resumeRazorpaySubscription')
            .call({});
        data = Map<String, dynamic>.from(result.data as Map);
      }

      if (data['success'] == true) {
        await PlanService.instance.refreshSubscription();
        return true;
      }

      _lastError = data['error'] as String? ?? 'Failed to resume subscription';
      return false;
    } catch (e) {
      AppLogger.error('RazorpayService: Resume error', e);
      _lastError = 'Failed to resume subscription';
      return false;
    } finally {
      isLoading.value = false;
    }
  }

  /// Restore subscription status from server
  Future<bool> restoreSubscription() async {
    try {
      await PlanService.instance.refreshSubscription();
      return PlanService.instance.currentPlan != UserPlan.free;
    } catch (e) {
      AppLogger.error('RazorpayService: Restore error', e);
      return false;
    }
  }

  /// DEBUG ONLY: Delete subscription for testing
  /// This immediately removes the subscription from Firestore
  Future<bool> debugDeleteSubscription() async {
    try {
      isLoading.value = true;

      final Map<String, dynamic> data;
      if (_isDesktop) {
        // Use direct HTTP call on desktop platforms
        data = await _callCloudFunction('debugDeleteSubscription');
      } else {
        final functions = FirebaseFunctions.instance;
        final result = await functions
            .httpsCallable('debugDeleteSubscription')
            .call({});
        data = Map<String, dynamic>.from(result.data as Map);
      }

      if (data['success'] == true) {
        await PlanService.instance.refreshSubscription();
        return true;
      }

      _lastError = data['error'] as String? ?? 'Failed to delete subscription';
      return false;
    } catch (e) {
      AppLogger.error('RazorpayService: Debug delete error', e);
      _lastError = 'Failed to delete subscription';
      return false;
    } finally {
      isLoading.value = false;
    }
  }
}
