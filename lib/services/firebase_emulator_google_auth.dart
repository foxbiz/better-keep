import 'package:firebase_auth/firebase_auth.dart';

/// Deterministic Google identity accepted only by the Firebase Auth emulator.
///
/// The Auth emulator accepts a literal JSON ID-token payload for federated
/// credentials. Production Firebase rejects this unsigned value.
class FirebaseEmulatorGoogleAuth {
  FirebaseEmulatorGoogleAuth._();

  static const String email = 'google.user@emulator.test';
  static const String subject = 'better-keep-google-emulator-user';

  static const String idToken =
      '{"sub":"$subject","email":"$email","email_verified":true,'
      '"name":"Google Emulator User","given_name":"Google",'
      '"family_name":"Emulator User"}';

  static OAuthCredential credential() {
    return GoogleAuthProvider.credential(idToken: idToken);
  }
}
