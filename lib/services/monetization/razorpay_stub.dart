import 'dart:async';
import 'dart:io';

import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Stub implementations for non-web platforms
/// These are only used on mobile (which uses native Razorpay SDK)
/// Desktop uses:
/// - Debug mode: Local server serves checkout HTML (Razorpay test mode)
/// - Release mode: Hosted page on betterkeep.app (Razorpay live mode)

/// The base URL for the hosted checkout page (used in release mode)
/// This must be a domain whitelisted in Razorpay dashboard for live mode
const String _checkoutBaseUrl = 'https://betterkeep.app/desktop-checkout.html';

/// Open Razorpay checkout for subscription
Future<RazorpayPaymentResult> openSubscriptionCheckout({
  required String keyId,
  required String subscriptionId,
  required String name,
  required String description,
  required String email,
  String? contact,
  String theme = '#FFA726',
}) async {
  // On mobile, use native Razorpay SDK (razorpay_flutter package)
  // This stub is for desktop which should use openDesktopSubscriptionCheckout
  return RazorpayPaymentResult.failed('Use native checkout on this platform');
}

/// Open Razorpay checkout for one-time order
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
  // On mobile, use native Razorpay SDK (razorpay_flutter package)
  // This stub is for desktop which should use openDesktopOrderCheckout
  return RazorpayPaymentResult.failed('Use native checkout on this platform');
}

/// Open subscription checkout via hosted page + local callback for desktop/Android
/// This is used on Windows, Linux, and Android (when Google Play billing is unavailable)
Future<RazorpayPaymentResult> openDesktopSubscriptionCheckout({
  required String keyId,
  required String subscriptionId,
  required String name,
  required String description,
  required String email,
  String theme = '#FFA726',
}) async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isAndroid) {
    return RazorpayPaymentResult.failed('Platform not supported');
  }

  AppLogger.log(
    'RazorpayStub: openDesktopSubscriptionCheckout called with theme: $theme',
  );
  AppLogger.log(
    'RazorpayStub: Opening subscription checkout for $subscriptionId (platform: ${Platform.operatingSystem})',
  );

  return _openHostedCheckout(
    type: 'subscription',
    params: {
      'key': keyId,
      'subscription_id': subscriptionId,
      'name': name,
      'description': description,
      'email': email,
      'theme': theme,
    },
  );
}

/// Open order checkout via hosted page + local callback for desktop/Android
Future<RazorpayPaymentResult> openDesktopOrderCheckout({
  required String keyId,
  required String orderId,
  required int amount,
  required String currency,
  required String name,
  required String description,
  required String email,
  String theme = '#FFA726',
}) async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isAndroid) {
    return RazorpayPaymentResult.failed('Platform not supported');
  }

  AppLogger.log(
    'RazorpayStub: Opening order checkout for $orderId (platform: ${Platform.operatingSystem})',
  );

  return _openHostedCheckout(
    type: 'order',
    params: {
      'key': keyId,
      'order_id': orderId,
      'amount': amount.toString(),
      'currency': currency,
      'name': name,
      'description': description,
      'email': email,
      'theme': theme,
    },
  );
}

/// Global navigator key for showing dialogs without context
GlobalKey<NavigatorState>? _navigatorKey;

/// Set the navigator key for showing dialogs
void setNavigatorKey(GlobalKey<NavigatorState> key) {
  AppLogger.log('RazorpayStub: Navigator key set');
  _navigatorKey = key;
}

/// Open hosted checkout page and wait for callback
///
/// In debug mode:
/// - Serves checkout HTML from local server (Razorpay test mode)
/// - Good for development/testing
///
/// In release mode:
/// - Opens checkout page hosted on betterkeep.app (Razorpay live mode)
/// - Callback redirects to local server
Future<RazorpayPaymentResult> _openHostedCheckout({
  required String type,
  required Map<String, String> params,
}) async {
  HttpServer? server;
  Timer? timeoutTimer;

  try {
    // Start local server to receive callback (and serve checkout in debug mode)
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    final completer = Completer<RazorpayPaymentResult>();

    AppLogger.log(
      'RazorpayStub: Started server on port $port (debug: $kDebugMode)',
    );

    // Set a timeout of 10 minutes for payment completion
    timeoutTimer = Timer(const Duration(minutes: 10), () {
      if (!completer.isCompleted) {
        AppLogger.log('RazorpayStub: Payment timeout');
        completer.complete(
          RazorpayPaymentResult.failed('Payment timed out. Please try again.'),
        );
      }
    });

    // Handle requests
    server.listen((request) async {
      final path = request.uri.path;
      AppLogger.log('RazorpayStub: Received request: $path');

      // Add CORS headers
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST');

      if (path == '/checkout' && kDebugMode) {
        // In debug mode, serve the checkout HTML locally
        final callbackUrl = 'http://localhost:$port/callback';
        final html = _generateCheckoutHtml(
          type: type,
          params: params,
          callbackUrl: callbackUrl,
        );
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(html);
        await request.response.close();
      } else if (path == '/callback') {
        final queryParams = request.uri.queryParameters;
        final status = queryParams['status'];

        AppLogger.log('RazorpayStub: Received callback with status: $status');

        // Send success response page
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(
            _generateResultHtml(
              success: status == 'success',
              message: status == 'success'
                  ? 'Payment successful! You can close this window and return to the app.'
                  : status == 'cancelled'
                  ? 'Payment cancelled. You can close this window.'
                  : queryParams['message'] ?? 'Payment failed.',
            ),
          );
        await request.response.close();

        if (!completer.isCompleted) {
          if (status == 'success') {
            completer.complete(
              RazorpayPaymentResult(
                success: true,
                paymentId: queryParams['payment_id'],
                subscriptionId: queryParams['subscription_id'],
                orderId: queryParams['order_id'],
                signature: queryParams['signature'],
              ),
            );
          } else if (status == 'cancelled') {
            completer.complete(RazorpayPaymentResult.cancelled());
          } else {
            completer.complete(
              RazorpayPaymentResult.failed(
                queryParams['message'] ?? 'Payment failed',
              ),
            );
          }
        }
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not Found');
        await request.response.close();
      }
    });

    // Build the checkout URL
    final Uri checkoutUri;
    if (kDebugMode) {
      // In debug mode, serve checkout from local server
      checkoutUri = Uri.parse('http://localhost:$port/checkout');
      AppLogger.log('RazorpayStub: Using local checkout (test mode)');
    } else {
      // In release mode, use hosted checkout page
      final callbackUrl = Uri.encodeFull('http://localhost:$port/callback');
      checkoutUri = Uri.parse(_checkoutBaseUrl).replace(
        queryParameters: {...params, 'type': type, 'callback': callbackUrl},
      );
      AppLogger.log('RazorpayStub: Using hosted checkout (live mode)');
    }

    AppLogger.log('RazorpayStub: Opening browser with URL: $checkoutUri');

    final launched = await launchUrl(
      checkoutUri,
      mode: LaunchMode.externalApplication,
    );

    if (!launched) {
      AppLogger.error('RazorpayStub: Failed to launch browser');
      return RazorpayPaymentResult.failed(
        'Could not open browser. Please try again.',
      );
    }

    // Show a dialog to inform user about the browser payment
    _showWaitingDialog();

    // Wait for the result
    final result = await completer.future;

    // Dismiss the waiting dialog
    _dismissWaitingDialog();

    return result;
  } catch (e) {
    AppLogger.error('RazorpayStub: Error during checkout', e);
    return RazorpayPaymentResult.failed('Failed to process payment: $e');
  } finally {
    timeoutTimer?.cancel();
    await server?.close(force: true);
    AppLogger.log('RazorpayStub: Callback server closed');
  }
}

/// Show a dialog indicating payment is in progress
void _showWaitingDialog() {
  final context = _navigatorKey?.currentContext;
  if (context == null) return;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Row(
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 16),
          Text('Payment in Progress'),
        ],
      ),
      content: const Text(
        'Please complete the payment in your browser.\n\n'
        'This dialog will close automatically once the payment is complete.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

/// Dismiss the waiting dialog
void _dismissWaitingDialog() {
  final context = _navigatorKey?.currentContext;
  if (context == null) return;

  // Pop the dialog if it's still showing
  if (Navigator.of(context).canPop()) {
    Navigator.of(context).pop();
  }
}

/// Generate result HTML page shown after payment
String _generateResultHtml({required bool success, required String message}) {
  final color = success ? '#4CAF50' : '#f44336';
  final icon = success ? '✓' : '✕';
  final title = success ? 'Payment Successful!' : 'Payment Failed';

  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>$title</title>
  <style>
    body {
      margin: 0;
      padding: 40px;
      background: #1a1a1a;
      color: white;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: calc(100vh - 80px);
      text-align: center;
    }
    .container {
      max-width: 400px;
    }
    .icon {
      width: 80px;
      height: 80px;
      border-radius: 50%;
      background: $color;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0 auto 24px;
      font-size: 40px;
    }
    h1 {
      margin: 0 0 16px;
      font-size: 24px;
    }
    p {
      margin: 0;
      color: #aaa;
      line-height: 1.5;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="icon">$icon</div>
    <h1>$title</h1>
    <p>$message</p>
  </div>
  <script>
    // Try to close the window after a delay
    setTimeout(() => {
      window.close();
    }, 3000);
  </script>
</body>
</html>
''';
}

/// Generate checkout HTML for local server (debug mode)
String _generateCheckoutHtml({
  required String type,
  required Map<String, String> params,
  required String callbackUrl,
}) {
  final key = _escapeJs(params['key'] ?? '');
  final subscriptionId = _escapeJs(params['subscription_id'] ?? '');
  final orderId = _escapeJs(params['order_id'] ?? '');
  final amount = params['amount'] ?? '0';
  final currency = _escapeJs(params['currency'] ?? 'INR');
  final name = _escapeJs(params['name'] ?? 'Better Keep Notes');
  final description = _escapeJs(params['description'] ?? '');
  final email = _escapeJs(params['email'] ?? '');
  final theme = _escapeJs(params['theme'] ?? '#FFA726');

  final isSubscription = type == 'subscription';

  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Payment - ${_escapeHtml(params['name'] ?? 'Better Keep')}</title>
  <script src="https://checkout.razorpay.com/v1/checkout.js"></script>
  <style>
    body {
      margin: 0;
      padding: 40px;
      background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
      color: white;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: calc(100vh - 80px);
    }
    .container {
      text-align: center;
      max-width: 400px;
    }
    .logo {
      width: 80px;
      height: 80px;
      margin: 0 auto 24px;
      background: $theme;
      border-radius: 20px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 40px;
    }
    h1 {
      margin: 0 0 8px;
      font-size: 24px;
    }
    .subtitle {
      margin: 0 0 32px;
      color: #aaa;
      font-size: 14px;
    }
    .test-badge {
      display: inline-block;
      background: $theme;
      color: #000;
      padding: 4px 12px;
      border-radius: 4px;
      font-size: 12px;
      font-weight: 600;
      margin-bottom: 24px;
    }
    .loading p {
      margin-top: 16px;
      color: #888;
    }
    .spinner {
      width: 48px;
      height: 48px;
      border: 4px solid rgba(255, 167, 38, 0.2);
      border-top-color: #FFA726;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin: 0 auto;
    }
    @keyframes spin {
      to { transform: rotate(360deg); }
    }
    .error {
      background: rgba(244, 67, 54, 0.1);
      border: 1px solid rgba(244, 67, 54, 0.3);
      border-radius: 12px;
      padding: 24px;
      margin-top: 24px;
    }
    .error h2 {
      color: #f44336;
      margin: 0 0 12px;
      font-size: 18px;
    }
    .error p {
      color: #ccc;
      margin: 0;
    }
    .btn {
      display: inline-block;
      padding: 12px 32px;
      background: #FFA726;
      color: #000;
      border: none;
      border-radius: 8px;
      font-size: 16px;
      cursor: pointer;
      margin-top: 16px;
    }
    .btn:hover {
      background: #FFB74D;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">📝</div>
    <h1>Better Keep Notes</h1>
    <p class="subtitle">Secure Payment</p>
    <div class="test-badge">⚠️ TEST MODE</div>

    <div class="loading" id="loading">
      <div class="spinner"></div>
      <p>Opening payment window...</p>
    </div>

    <div class="error" id="error" style="display: none;">
      <h2>Payment Error</h2>
      <p id="error-message">Something went wrong.</p>
      <button class="btn" onclick="location.reload()">Try Again</button>
    </div>
  </div>

  <script>
    const callbackUrl = '$callbackUrl';

    function redirectWithResult(status, params = {}) {
      const url = new URL(callbackUrl);
      url.searchParams.set('status', status);
      Object.entries(params).forEach(([key, value]) => {
        if (value) url.searchParams.set(key, value);
      });
      window.location.href = url.toString();
    }

    function showError(message) {
      document.getElementById('loading').style.display = 'none';
      document.getElementById('error').style.display = 'block';
      document.getElementById('error-message').textContent = message;
    }

    try {
      const options = ${isSubscription ? '''
      {
        key: '$key',
        subscription_id: '$subscriptionId',
        name: '$name',
        description: '$description',
        image: 'https://betterkeep.app/icons/logo.png',
        prefill: { email: '$email' },
        theme: { color: '$theme' },
        modal: {
          ondismiss: function() { redirectWithResult('cancelled'); },
          escape: true,
          animation: true
        },
        handler: function(response) {
          redirectWithResult('success', {
            payment_id: response.razorpay_payment_id,
            subscription_id: response.razorpay_subscription_id,
            signature: response.razorpay_signature
          });
        }
      }''' : '''
      {
        key: '$key',
        order_id: '$orderId',
        amount: $amount,
        currency: '$currency',
        name: '$name',
        description: '$description',
        image: 'https://betterkeep.app/icons/logo.png',
        prefill: { email: '$email' },
        theme: { color: '$theme' },
        modal: {
          ondismiss: function() { redirectWithResult('cancelled'); },
          escape: true,
          animation: true
        },
        handler: function(response) {
          redirectWithResult('success', {
            payment_id: response.razorpay_payment_id,
            order_id: response.razorpay_order_id,
            signature: response.razorpay_signature
          });
        }
      }'''};

      const rzp = new Razorpay(options);

      rzp.on('payment.failed', function(response) {
        redirectWithResult('error', {
          message: response.error.description || 'Payment failed'
        });
      });

      setTimeout(() => {
        document.getElementById('loading').innerHTML = '<p>Razorpay checkout should open automatically.</p>';
        rzp.open();
      }, 500);

    } catch (e) {
      showError(e.message || 'Failed to initialize payment');
    }
  </script>
</body>
</html>
''';
}

/// Escape string for safe use in JavaScript
String _escapeJs(String value) {
  return value
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r');
}

/// Escape string for safe use in HTML
String _escapeHtml(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
