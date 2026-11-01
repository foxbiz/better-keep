// Run the normal Storage emulator on 9199, then start isolated test Auth:
// npx firebase emulators:start --only auth --project demo-better-keep-storage-lan
//   --config integration_test/storage_emulator_lan.firebase.json
// Run on a disposable simulator/emulator:
// flutter test integration_test/storage_emulator_lan_test.dart -d <device>
//   --dart-define=EMULATOR_HOST=<Mac LAN IP>
// Uses only a demo project, temporary Auth users, and temporary Storage objects.
import 'dart:convert';

import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:better_keep/services/firebase_storage_emulator_transport.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _project = 'demo-better-keep-storage-lan';
const _host = String.fromEnvironment('EMULATOR_HOST');

String _customToken(String uid, {required bool pro}) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now();
  return '${part({'alg': 'none', 'typ': 'JWT'})}.${part({
    'iss': 'test@example.com',
    'sub': 'test@example.com',
    'aud': 'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit',
    'iat': now.millisecondsSinceEpoch ~/ 1000,
    'exp': now.millisecondsSinceEpoch ~/ 1000 + 3600,
    'uid': uid,
    'claims': {'plan': pro ? 'pro' : 'free', 'planExpiresAt': now.add(const Duration(days: 1)).millisecondsSinceEpoch},
  })}.';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'LAN Storage uploads work and still enforce owner and Pro rules',
    (tester) async {
      expect(
        _host,
        isNotEmpty,
        reason: 'Provide the Mac LAN IP as EMULATOR_HOST',
      );
      final apps = <FirebaseApp>[];
      final users = <User>[];
      Reference? uploaded;
      Future<({FirebaseStorage storage, User user})> client(
        String suffix, {
        bool relay = true,
        bool pro = true,
      }) async {
        final app = await Firebase.initializeApp(
          name: 'storage-lan-$suffix-${DateTime.now().microsecondsSinceEpoch}',
          options: FirebaseOptions(
            apiKey: 'A00000000000000000000000000000000000000',
            appId: '1:1234567890:ios:1234567890abcdef',
            messagingSenderId: '1234567890',
            projectId: _project,
            // FlutterFire's native emulator guard is keyed by bucket. Give
            // each independent SDK client its own disposable bucket.
            storageBucket: '$_project-$suffix.appspot.com',
          ),
        );
        apps.add(app);
        final auth = FirebaseAuth.instanceFor(app: app);
        await auth.useAuthEmulator(_host, 9098, automaticHostMapping: false);
        final uid = 'lan-$suffix-${DateTime.now().microsecondsSinceEpoch}';
        final user = (await auth.signInWithCustomToken(
          _customToken(uid, pro: pro),
        )).user!;
        users.add(user);
        expect(
          (await user.getIdTokenResult()).claims?['plan'],
          pro ? 'pro' : 'free',
        );
        final storage = FirebaseStorage.instanceFor(app: app);
        final endpoint = relay
            ? await configureStorageEmulatorTransport(
                const FirebaseEmulatorEndpoints(_host),
                projectId: _project,
              )
            : Uri.parse('http://$_host:9199');
        await storage.useStorageEmulator(
          endpoint.host,
          endpoint.port,
          automaticHostMapping: false,
        );
        storage.setMaxUploadRetryTime(const Duration(seconds: 5));
        return (storage: storage, user: user);
      }

      final denied = isA<FirebaseException>().having(
        (error) => error.code,
        'code',
        'unauthorized',
      );
      final bytes = Uint8List.fromList(
        List.generate(512 * 1024, (index) => index % 251),
      );
      try {
        if (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS) {
          final direct = await client('direct', relay: false);
          await expectLater(
            direct.storage
                .ref('users/${direct.user.uid}/notes/image.jpg')
                .putData(bytes),
            throwsA(denied),
          );
          debugPrint('VERIFIED: direct LAN Storage reproduces unauthorized');
        }
        final pro = await client('pro');
        uploaded = pro.storage.ref(
          'users/${pro.user.uid}/notes/image space.jpg',
        );
        await uploaded.putData(bytes).timeout(const Duration(seconds: 30));
        expect(await uploaded.getData(), bytes);
        expect((await uploaded.getMetadata()).size, bytes.length);
        expect(await uploaded.getDownloadURL(), contains('/v0/b/'));
        await expectLater(
          pro.storage.ref('users/another-user/notes/image.jpg').putData(bytes),
          throwsA(denied),
        );
        final free = await client('free', pro: false);
        await expectLater(
          free.storage
              .ref('users/${free.user.uid}/notes/image.jpg')
              .putData(bytes),
          throwsA(denied),
        );
        debugPrint(
          'VERIFIED: LAN upload, download, metadata, URL; free and non-owner writes denied',
        );
      } finally {
        await uploaded?.delete();
        for (final user in users) {
          await user.delete();
        }
        for (final app in apps) {
          await app.delete();
        }
      }
    },
  );
}
