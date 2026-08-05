/// Stub implementation for non-web platforms
/// This file is used when dart.library.html is not available
library;

import 'dart:async';

String currentOAuthClientOrigin() => '';

/// Result class to hold token or error message (stub)
class OAuthPopupResult {
  final String? completionCode;
  final String? transactionId;
  final String? error;
  final bool cancelled;
  final bool linked;

  OAuthPopupResult({
    this.completionCode,
    this.transactionId,
    this.error,
    this.cancelled = false,
    this.linked = false,
  });

  bool get isSuccess => completionCode != null || linked;
  bool get isError => error != null && !cancelled;
}

/// Opens OAuth popup - stub for non-web (does nothing)
Future<OAuthPopupResult> openOAuthPopup(
  String url, {
  required String expectedTransactionId,
}) async {
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
