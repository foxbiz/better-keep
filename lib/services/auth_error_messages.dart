import 'package:firebase_auth/firebase_auth.dart';

String resolveSignInErrorMessage({
  required String provider,
  required Object error,
}) {
  final normalized = _normalizedAuthError(error);

  if (provider == 'apple' && normalized.contains('invalid-credential')) {
    return 'Apple sign-in could not be verified. Please restart the app and '
        'try signing in with Apple again.';
  }
  if (normalized.contains('account-exists-with-different-credential') ||
      normalized.contains('email-already-in-use')) {
    return 'This email is already linked to another account. Try signing in '
        'with a different method (Google, Facebook, etc.) or use the Connected '
        'Accounts feature to link providers.';
  }
  if (normalized.contains('user-not-found')) {
    return 'No account found with this email. Please sign up first.';
  }
  if (normalized.contains('wrong-password') ||
      normalized.contains('invalid-credential')) {
    return 'Invalid credentials. Please check your password and try again.';
  }
  if (normalized.contains('user-disabled')) {
    return 'This account has been disabled. Please contact support.';
  }
  if (normalized.contains('too-many-requests')) {
    return 'Too many failed attempts. Please try again later.';
  }
  if (normalized.contains('network') || normalized.contains('timeout')) {
    return 'Network error. Please check your internet connection.';
  }
  if (normalized.contains('cancelled') ||
      normalized.contains('canceled') ||
      normalized.contains('popup-closed') ||
      normalized.contains('user-cancelled')) {
    return 'Sign in was cancelled.';
  }
  if (normalized.contains('permission-denied')) {
    return 'Permission denied. Please contact support.';
  }
  if (normalized.contains('unavailable')) {
    return 'Service temporarily unavailable. Please try again later.';
  }
  if (normalized.contains('internal-error')) {
    return 'Sign in failed. This might happen if your account does not have '
        'an email associated. Please try another sign-in method.';
  }
  if (normalized.contains('web-context-cancelled')) {
    return 'Sign in window was closed. Please try again.';
  }
  if (normalized.contains('insecure') || normalized.contains('https')) {
    return 'Please use HTTPS for secure sign in. Go to '
        'https://betterkeep.app';
  }
  if (error is FirebaseAuthException) {
    return error.message ?? 'Authentication failed. Please try again.';
  }
  if (error is Exception) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.length < 150) return message;
  }
  return 'Sign in failed. Please try again.';
}

bool isInsecureSignInError(Object error) {
  final normalized = _normalizedAuthError(error);
  return normalized.contains('insecure') || normalized.contains('https');
}

String _normalizedAuthError(Object error) {
  if (error is FirebaseAuthException) {
    return '${error.code} ${error.message ?? ''}'.toLowerCase();
  }
  return error.toString().toLowerCase();
}
