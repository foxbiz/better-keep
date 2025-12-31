import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:better_keep/utils/logger.dart';
import 'package:web/web.dart' as web;

web.Window? _popup;
StreamSubscription<web.MessageEvent>? _messageSubscription;
Completer<OAuthPopupResult>? _popupCompleter;
Timer? _popupCheckTimer;
bool _receivedMessage = false;

/// Result class to hold token or error message
class OAuthPopupResult {
  final String? token;
  final String? error;
  final bool cancelled;

  OAuthPopupResult({this.token, this.error, this.cancelled = false});

  bool get isSuccess => token != null;
  bool get isError => error != null && !cancelled;
}

/// Opens OAuth in a popup window and waits for the token via postMessage
Future<OAuthPopupResult> openOAuthPopup(String url) async {
  // Close any existing popup
  _popup?.close();
  _messageSubscription?.cancel();
  _popupCheckTimer?.cancel();
  _receivedMessage = false;

  _popupCompleter = Completer<OAuthPopupResult>();

  // Calculate popup position (center of screen)
  final width = 500;
  final height = 600;
  final screen = web.window.screen;
  final left = (screen.width - width) ~/ 2;
  final top = (screen.height - height) ~/ 2;

  // Create a loading page HTML to show immediately
  final loadingHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Signing In - Better Keep</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0;
    }
    .container {
      background: white;
      border-radius: 16px;
      padding: 40px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
      max-width: 400px;
    }
    .spinner {
      width: 50px;
      height: 50px;
      border: 4px solid #f3f3f3;
      border-top: 4px solid #6750A4;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin: 0 auto 20px;
    }
    @keyframes spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }
    h2 { color: #333; margin-bottom: 8px; }
    p { color: #666; }
  </style>
</head>
<body>
  <div class="container">
    <div class="spinner"></div>
    <h2>Signing In</h2>
    <p>Please wait...</p>
  </div>
</body>
</html>
''';

  // Open popup with about:blank first, then write loading page
  _popup = web.window.open(
    'about:blank',
    'oauth_popup',
    'width=$width,height=$height,left=$left,top=$top,scrollbars=yes,resizable=yes',
  );

  if (_popup == null) {
    return OAuthPopupResult(
      cancelled: true,
      error: 'Popup was blocked. Please allow popups for this site.',
    );
  }

  // Write loading page to popup immediately
  try {
    _popup!.document.open();
    _popup!.document.write(loadingHtml.toJS);
    _popup!.document.close();
  } catch (e) {
    AppLogger.log('Error writing loading page: $e');
  }

  // Navigate to actual OAuth URL after a brief moment to let loading page render
  Future.delayed(Duration(milliseconds: 150), () {
    try {
      _popup?.location.href = url;
    } catch (e) {
      AppLogger.log('Error navigating popup: $e');
    }
  });

  // Listen for postMessage from popup
  _messageSubscription = web.window.onMessage.listen((event) {
    // Log all messages for debugging
    AppLogger.log('Received postMessage from origin: ${event.origin}');

    // Convert data to a usable format
    String? type;
    String? token;
    String? error;

    try {
      final data = event.data;

      if (data != null && data.isA<JSObject>()) {
        // Use js_interop to access JavaScript object properties
        final jsData = data as JSObject;
        type = jsData.getProperty<JSAny?>('type'.toJS)?.dartify()?.toString();
        token = jsData.getProperty<JSAny?>('token'.toJS)?.dartify()?.toString();
        error = jsData.getProperty<JSAny?>('error'.toJS)?.dartify()?.toString();
      }
    } catch (e) {
      AppLogger.log('Error parsing postMessage data: $e');
      return;
    }

    AppLogger.log(
      'Received OAuth message: type=$type, hasToken=${token != null}, error=$error',
    );

    if (type == 'oauth_success' && token != null) {
      _receivedMessage = true;
      _popupCheckTimer?.cancel();
      _messageSubscription?.cancel();

      // Send close command to popup
      try {
        if (_popup != null) {
          final message = {'type': 'oauth_close'}.jsify();
          _popup!.postMessage(message, '*'.toJS);
        }
      } catch (e) {
        AppLogger.log('Error sending close command: $e');
      }

      // Close popup from parent side
      _popup?.close();

      if (_popupCompleter != null && !_popupCompleter!.isCompleted) {
        _popupCompleter!.complete(OAuthPopupResult(token: token));
      }
    } else if (type == 'oauth_error') {
      _receivedMessage = true;
      AppLogger.log('OAuth error from popup: $error');
      _popupCheckTimer?.cancel();
      _messageSubscription?.cancel();

      // Send close command to popup
      try {
        if (_popup != null) {
          final message = {'type': 'oauth_close'}.jsify();
          _popup!.postMessage(message, '*'.toJS);
        }
      } catch (e) {
        AppLogger.log('Error sending close command: $e');
      }

      _popup?.close();
      if (_popupCompleter != null && !_popupCompleter!.isCompleted) {
        _popupCompleter!.complete(
          OAuthPopupResult(error: error ?? 'Authentication failed'),
        );
      }
    } else if (type == 'oauth_cancelled') {
      _receivedMessage = true;
      _popupCheckTimer?.cancel();
      _messageSubscription?.cancel();
      _popup?.close();
      if (_popupCompleter != null && !_popupCompleter!.isCompleted) {
        _popupCompleter!.complete(OAuthPopupResult(cancelled: true));
      }
    } else if (type == 'oauth_link_success') {
      // Handle successful account linking (no token returned, just success)
      _receivedMessage = true;
      AppLogger.log('OAuth link success from popup');
      _popupCheckTimer?.cancel();
      _messageSubscription?.cancel();

      // Send close command to popup
      try {
        if (_popup != null) {
          final message = {'type': 'oauth_close'}.jsify();
          _popup!.postMessage(message, '*'.toJS);
        }
      } catch (e) {
        AppLogger.log('Error sending close command: $e');
      }

      _popup?.close();
      if (_popupCompleter != null && !_popupCompleter!.isCompleted) {
        // Return empty token to indicate success (not an error, not cancelled)
        _popupCompleter!.complete(OAuthPopupResult(token: 'link_success'));
      }
    }
  });

  // Check if popup was closed manually (with delay to avoid race condition)
  _popupCheckTimer = Timer.periodic(Duration(milliseconds: 500), (timer) {
    if (_popup?.closed == true) {
      timer.cancel();
      // Wait a bit more to ensure postMessage has time to be processed
      Future.delayed(Duration(milliseconds: 300), () {
        if (!_receivedMessage &&
            _popupCompleter != null &&
            !_popupCompleter!.isCompleted) {
          AppLogger.log(
            'Popup closed without receiving message - treating as cancelled',
          );
          _popupCompleter!.complete(OAuthPopupResult(cancelled: true));
          _messageSubscription?.cancel();
        }
      });
    }
  });

  return _popupCompleter!.future;
}

/// Cleanup popup listener
void cleanupPopupListener() {
  _popup?.close();
  _popup = null;
  _messageSubscription?.cancel();
  _messageSubscription = null;
  _popupCheckTimer?.cancel();
  _popupCheckTimer = null;
  _popupCompleter = null;
  _receivedMessage = false;
}
