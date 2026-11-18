import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:better_keep/app.dart';
import 'package:better_keep/components/post_sign_in_recovery_view.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/firebase_backend.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/offline_firebase.dart';

void main() {
  testWidgets(
    'loading does not retry sign-in or manufacture an encryption failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await AppState.init();
      PackageInfo.setMockInitialValues(
        appName: 'QA',
        packageName: 'test.qa',
        version: '1.5.0',
        buildNumber: '109',
        buildSignature: 'test',
      );
      final backend = OfflineFirebase()..configure();
      final user = backend.auth.currentUser! as OfflineUser;
      final e2ee = E2EEService.instance;
      e2ee.status.value = E2EEStatus.notInitialized;
      AuthService.postSignInState.value = PostSignInState.running(
        PostSignInStage.accountInitialization,
      );
      addTearDown(() async {
        AuthService.cloudRecovery.stop();
        await backend.auth.changes.close();
        backend.firebaseSync.dispose();
        FirebaseBackend.resetForTesting();
        AuthService.postSignInState.value = PostSignInState.idle;
        e2ee.resetInitialization();
      });
      await tester.pumpWidget(const App());
      backend.auth.changes.add(user);
      await tester.pump();
      expect(find.text('Retry'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(
        user.tokenRequests,
        0,
        reason: 'The view must not start another sign-in attempt',
      );
      expect(e2ee.status.value, E2EEStatus.notInitialized);
      expect(find.byType(PostSignInRecoveryView), findsNothing);
      expect(
        find.text('Continue Offline'),
        findsNothing,
        reason: 'No local encryption key is usable',
      );
      final token = Completer<IdTokenResult>();
      user.tokenResponse = () => token.future;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Retry'));
      expect(user.tokenRequests, 1);
      token.completeError(
        FirebaseAuthException(code: 'network-request-failed'),
      );
      await tester.runAsync(() => pumpEventQueue(times: 100));
      await tester.pump();
      expect(find.text('Connection needed'), findsOneWidget);
      expect(find.text('Something went wrong'), findsNothing);
      expect(find.text('Continue Offline'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);
      AuthService.postSignInState.value = PostSignInState.recoverableFailure(
        PostSignInStage.accountInitialization,
        operation: 'deletion-precedence-fixture',
        accountDeletionInProgress: true,
        connectionUnavailable: true,
      );
      await tester.pump();
      expect(find.byIcon(Icons.wifi_off_rounded), findsNothing);
      expect(find.text('Connection needed'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(
        tester
            .widget<PostSignInRecoveryView>(find.byType(PostSignInRecoveryView))
            .message,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
