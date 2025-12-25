import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:flutter/material.dart';

/// Set navigator key - not needed on web, stub for interface compatibility
void setNavigatorKey(GlobalKey<NavigatorState> key) {
  // No-op on web - dialogs are handled by JS
}

/// JS Interop for Razorpay Checkout (Web)
@JS('openRazorpaySubscription')
external JSPromise<JSObject> _openRazorpaySubscription(JSObject options);

@JS('openRazorpayOrder')
external JSPromise<JSObject> _openRazorpayOrder(JSObject options);

/// Check if Razorpay SDK is loaded by checking window.Razorpay
bool isRazorpayLoaded() {
  try {
    // Check if window.Razorpay exists
    final razorpay = globalContext['Razorpay'];
    return razorpay != null && !razorpay.isUndefinedOrNull;
  } catch (_) {
    return false;
  }
}

/// Open Razorpay checkout for subscription (Web)
Future<RazorpayPaymentResult> openSubscriptionCheckout({
  required String keyId,
  required String subscriptionId,
  required String name,
  required String description,
  required String email,
  String? contact,
  String theme = '#FFA726',
}) async {
  if (!isRazorpayLoaded()) {
    return RazorpayPaymentResult.failed('Razorpay SDK not loaded');
  }

  try {
    final options =
        <String, dynamic>{
              'keyId': keyId,
              'subscriptionId': subscriptionId,
              'name': name,
              'description': description,
              'prefillEmail': email,
              'prefillContact': contact ?? '',
              'theme': theme,
            }.jsify()
            as JSObject;

    final result = await _openRazorpaySubscription(options).toDart;
    final resultMap = (result.dartify() as Map).cast<String, dynamic>();

    if (resultMap['success'] == true) {
      return RazorpayPaymentResult(
        success: true,
        paymentId: resultMap['razorpay_payment_id'] as String?,
        subscriptionId: resultMap['razorpay_subscription_id'] as String?,
        signature: resultMap['razorpay_signature'] as String?,
      );
    }

    return RazorpayPaymentResult.failed(
      resultMap['message'] as String? ?? 'Payment failed',
    );
  } catch (e) {
    // Check if user cancelled
    final errorStr = e.toString();
    if (errorStr.contains('cancelled') || errorStr.contains('canceled')) {
      return RazorpayPaymentResult.cancelled();
    }

    // Try to extract error details
    try {
      final jsError = e as JSObject;
      final errorMap = (jsError.dartify() as Map).cast<String, dynamic>();

      if (errorMap['cancelled'] == true) {
        return RazorpayPaymentResult.cancelled();
      }

      final errorDesc =
          errorMap['description'] as String? ??
          errorMap['message'] as String? ??
          'Payment failed';
      return RazorpayPaymentResult.failed(errorDesc);
    } catch (_) {
      return RazorpayPaymentResult.failed(errorStr);
    }
  }
}

/// Open Razorpay checkout for one-time order (Web)
Future<RazorpayPaymentResult> openOrderCheckout({
  required String keyId,
  required String orderId,
  required int amount,
  required String currency,
  required String name,
  required String description,
  required String email,
  String? contact,
  String theme = '#FFA726',
}) async {
  if (!isRazorpayLoaded()) {
    return RazorpayPaymentResult.failed('Razorpay SDK not loaded');
  }

  try {
    final options =
        <String, dynamic>{
              'keyId': keyId,
              'orderId': orderId,
              'amount': amount,
              'currency': currency,
              'name': name,
              'description': description,
              'prefillEmail': email,
              'prefillContact': contact ?? '',
              'theme': theme,
            }.jsify()
            as JSObject;

    final result = await _openRazorpayOrder(options).toDart;
    final resultMap = (result.dartify() as Map).cast<String, dynamic>();

    if (resultMap['success'] == true) {
      return RazorpayPaymentResult(
        success: true,
        paymentId: resultMap['razorpay_payment_id'] as String?,
        orderId: resultMap['razorpay_order_id'] as String?,
        signature: resultMap['razorpay_signature'] as String?,
      );
    }

    return RazorpayPaymentResult.failed(
      resultMap['message'] as String? ?? 'Payment failed',
    );
  } catch (e) {
    // Check if user cancelled
    final errorStr = e.toString();
    if (errorStr.contains('cancelled') || errorStr.contains('canceled')) {
      return RazorpayPaymentResult.cancelled();
    }

    // Try to extract error details
    try {
      final jsError = e as JSObject;
      final errorMap = (jsError.dartify() as Map).cast<String, dynamic>();

      if (errorMap['cancelled'] == true) {
        return RazorpayPaymentResult.cancelled();
      }

      final errorDesc =
          errorMap['description'] as String? ??
          errorMap['message'] as String? ??
          'Payment failed';
      return RazorpayPaymentResult.failed(errorDesc);
    } catch (_) {
      return RazorpayPaymentResult.failed(errorStr);
    }
  }
}

/// Desktop checkout stubs - not used on web
Future<RazorpayPaymentResult> openDesktopSubscriptionCheckout({
  required String keyId,
  required String subscriptionId,
  required String name,
  required String description,
  required String email,
}) async {
  // On web, this should not be called - use openSubscriptionCheckout instead
  return RazorpayPaymentResult.failed('Use web checkout on this platform');
}

Future<RazorpayPaymentResult> openDesktopOrderCheckout({
  required String keyId,
  required String orderId,
  required int amount,
  required String currency,
  required String name,
  required String description,
  required String email,
}) async {
  // On web, this should not be called - use openOrderCheckout instead
  return RazorpayPaymentResult.failed('Use web checkout on this platform');
}
