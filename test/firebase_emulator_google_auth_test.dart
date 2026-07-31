import 'dart:convert';

import 'package:better_keep/services/firebase_emulator_google_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates a deterministic google.com ID-token credential', () {
    final credential = FirebaseEmulatorGoogleAuth.credential();
    final payload = jsonDecode(credential.idToken!) as Map<String, dynamic>;

    expect(credential.providerId, 'google.com');
    expect(credential.signInMethod, 'google.com');
    expect(credential.accessToken, isNull);
    expect(payload['sub'], FirebaseEmulatorGoogleAuth.subject);
    expect(payload['email'], FirebaseEmulatorGoogleAuth.email);
    expect(payload['email_verified'], isTrue);
  });
}
