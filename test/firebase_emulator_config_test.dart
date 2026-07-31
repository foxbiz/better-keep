import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/services/firebase_scoped_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SharedPreferences> initializePreferences(
    Map<String, Object> values,
  ) async {
    SharedPreferences.setMockInitialValues(values);
    final preferences = await SharedPreferences.getInstance();
    FirebaseEmulatorConfig.init(preferences);
    return preferences;
  }

  test('reads the saved host and Google emulator mode', () async {
    await initializePreferences({
      'debug_firebase_environment': 'emulator',
      'debug_firebase_emulator_host': '192.168.1.42',
      'debug_firebase_google_auth_mode': 'real',
    });

    expect(FirebaseEmulatorConfig.suggestedPhysicalDeviceHost, '192.168.1.42');
    expect(
      FirebaseEmulatorConfig.savedGoogleAuthMode,
      GoogleEmulatorAuthMode.real,
    );
  });

  test(
    'only reusable debug Firebase preferences survive account clearing',
    () async {
      final preferences = await initializePreferences({
        'debug_firebase_environment': 'emulator',
        'debug_firebase_use_emulators': true,
        'debug_firebase_emulator_host': '192.168.1.42',
        'debug_firebase_google_auth_mode': 'real',
        'debug_firebase_runtime_emulator_host': '192.168.1.42',
        'debug_firebase_runtime_emulator_app_name':
            'better-keep-emulator-a1b2c3',
        'user_email': 'remove@example.com',
      });

      await FirebaseScopedPreferences.clearActiveAccountPreferences(
        preferences,
        scopeOverride: FirebaseLocalDataScope.live,
      );

      expect(preferences.getString('user_email'), isNull);
      expect(preferences.getString('debug_firebase_environment'), isNull);
      expect(preferences.getBool('debug_firebase_use_emulators'), isNull);
      expect(
        preferences.getString('debug_firebase_emulator_host'),
        '192.168.1.42',
      );
      expect(preferences.getString('debug_firebase_google_auth_mode'), 'real');
      expect(
        preferences.getString('debug_firebase_runtime_emulator_host'),
        '192.168.1.42',
      );
      expect(
        preferences.getString('debug_firebase_runtime_emulator_app_name'),
        'better-keep-emulator-a1b2c3',
      );
    },
  );
}
