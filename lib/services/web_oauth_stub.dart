/// Stub implementation for non-web platforms
/// This file is used when dart.library.html is not available
library;

import 'dart:async';

/// Result class to hold token or error message (stub)
class OAuthPopupResult {
  final String? token;
  final String? error;
  final bool cancelled;

  OAuthPopupResult({this.token, this.error, this.cancelled = false});

  bool get isSuccess => token != null;
  bool get isError => error != null && !cancelled;
}

/// Opens OAuth popup - stub for non-web (does nothing)
Future<OAuthPopupResult> openOAuthPopup(String url) async {
  // Not supported on non-web platforms
  return OAuthPopupResult(
    cancelled: true,
    error: 'Not supported on this platform',
  );
}

/// Cleanup popup listener - stub for non-web (does nothing)
void cleanupPopupListener() {
  // Not supported on non-web platforms
}
