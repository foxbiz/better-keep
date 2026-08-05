import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A process-independent authentication signal for notification callbacks.
/// Background notification actions run in a separate Flutter engine and must
/// not initialize Firebase merely to determine whether local note access is
/// still authorized.
class ReminderSessionService {
  ReminderSessionService._();

  static const _signedInKey = 'reminder_session_signed_in';
  static bool? _signedIn;

  static Future<void> setSignedIn(
    bool value, {
    SharedPreferences? preferences,
  }) async {
    _signedIn = value;
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.setBool(
      FirebaseScopedPreferences.keyForPreferences(_signedInKey, prefs),
      value,
    );
  }

  static Future<bool> isSignedIn({SharedPreferences? preferences}) async {
    final cached = _signedIn;
    if (cached != null) return cached;
    final prefs = preferences ?? await SharedPreferences.getInstance();
    return _signedIn =
        prefs.getBool(
          FirebaseScopedPreferences.keyForPreferences(_signedInKey, prefs),
        ) ??
        false;
  }

  static void resetCacheForTesting() {
    _signedIn = null;
  }
}
