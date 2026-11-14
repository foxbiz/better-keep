import 'dart:convert';

import 'package:flutter/services.dart';

import 'dart:io';

import 'package:better_keep/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:better_keep/services/e2ee/device_authorization.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/utils/authenticated_startup_routing.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _FailingInstallPreference extends InMemorySharedPreferencesStore {
  _FailingInstallPreference(this.throws) : super.withData({});
  final bool throws;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (throws) throw StateError('preferences unavailable');
    return false;
  }
}

class _UnreadableInstallMarker extends Fake implements File {
  _UnreadableInstallMarker(this.path);
  @override
  final String path;
  @override
  Directory get parent => File(path).parent;
  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      throw FileSystemException('unreadable marker', path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory installation;
  late File marker;
  setUp(() async {
    installation = await Directory.systemTemp.createTemp('bkn-install-reset-');
    marker = File('${installation.path}/identity-reset');
  });
  tearDown(() => installation.delete(recursive: true));

  for (final evidence in [
    'legacy-marker',
    'live-account',
    'emulator-account',
    'library',
    'unreadable-library',
  ]) {
    test('iOS preserves identity with $evidence', () async {
      SharedPreferences.setMockInitialValues({
        if (evidence == 'legacy-marker') 'has_launched_before': true,
        if (evidence == 'live-account') 'user_uid': 'synthetic',
        if (evidence == 'emulator-account')
          'firebase_emulator.user_email': 'qa@emulator.test',
      });
      final prefs = await SharedPreferences.getInstance();
      var signsOut = 0;
      await AuthService.resetFreshIosInstall(
        prefs,
        installMarker: marker,
        hasLocalLibrary: () async {
          if (evidence == 'unreadable-library') {
            throw const FileSystemException('locked');
          }
          return evidence == 'library';
        },
        clearIdentity: () async => fail('Existing identity must be preserved'),
        signOut: () async {
          signsOut++;
        },
      );
      expect(signsOut, evidence == 'unreadable-library' ? 1 : 0);
      expect(await marker.readAsString(), 'complete');
    });
  }

  for (final throws in [false, true]) {
    test(
      'durable iOS marker survives preferences ${throws ? 'exception' : 'false result'}',
      () async {
        SharedPreferences.setMockInitialValues({});
        final previous = SharedPreferencesStorePlatform.instance;
        SharedPreferencesStorePlatform.instance = _FailingInstallPreference(
          throws,
        );
        addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
        var clears = 0;
        var signOuts = 0;
        Future<void> reset(SharedPreferences prefs) =>
            AuthService.resetFreshIosInstall(
              prefs,
              installMarker: marker,
              hasLocalLibrary: () async => false,
              clearIdentity: () async {
                clears++;
              },
              signOut: () async {
                signOuts++;
              },
            );
        await reset(await SharedPreferences.getInstance());
        // Simulate a restart with the failed preference write absent from disk.
        SharedPreferences.setMockInitialValues({});
        await reset(await SharedPreferences.getInstance());
        expect(clears, 1);
        expect(signOuts, 1);
      },
    );
  }

  test(
    'a failed iOS reinstall reset retries before trusting the install',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var clears = 0;
      var signOuts = 0;
      Future<void> reset() => AuthService.resetFreshIosInstall(
        prefs,
        installMarker: marker,
        hasLocalLibrary: () async => false,
        clearIdentity: () async {
          clears++;
        },
        signOut: () async {
          if (++signOuts == 1) throw StateError('interrupted');
        },
      );
      await expectLater(reset(), throwsStateError);
      expect(prefs.getBool('has_launched_before'), isNot(true));
      await reset();
      await reset();
      expect(clears, 2);
      expect(signOuts, 2);
    },
  );

  test('iOS cannot trust a reset until its install marker commits', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final blocker = File('${installation.path}/blocked');
    await blocker.writeAsString('fixture');
    final blockedMarker = File('${blocker.path}/identity-reset');
    var clears = 0;
    Future<void> reset() => AuthService.resetFreshIosInstall(
      prefs,
      installMarker: blockedMarker,
      hasLocalLibrary: () async => false,
      clearIdentity: () async {
        clears++;
      },
      signOut: () async {},
    );
    await expectLater(reset(), throwsA(isA<FileSystemException>()));
    expect(prefs.getBool('has_launched_before'), isNot(true));
    await blocker.delete();
    await reset();
    expect(await blockedMarker.readAsString(), 'complete');
    final afterReset = clears;
    await reset();
    expect(clears, afterReset);
  });

  for (final failure in <Exception>[
    PlatformException(code: 'path-unavailable'),
    MissingPluginException('path provider'),
  ]) {
    test('iOS preserves keys when the library probe throws $failure', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var signOuts = 0;
      Future<void> reset() => AuthService.resetFreshIosInstall(
        prefs,
        installMarker: marker,
        hasLocalLibrary: () async => throw failure,
        clearIdentity: () async => fail('Unknown evidence must preserve keys'),
        signOut: () async {
          signOuts++;
        },
      );
      await reset();
      expect(await marker.readAsString(), 'complete');
      await reset();
      expect(signOuts, 1);
    });
  }

  for (final evidence in ['unreadable', 'invalid-utf8', 'incomplete']) {
    test('iOS preserves identity and repairs a $evidence marker', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      if (evidence == 'invalid-utf8') await marker.writeAsBytes([255]);
      if (evidence == 'incomplete') await marker.writeAsString('partial');
      var signOuts = 0;
      await AuthService.resetFreshIosInstall(
        prefs,
        installMarker: evidence == 'unreadable'
            ? _UnreadableInstallMarker(marker.path)
            : marker,
        hasLocalLibrary: () async => false,
        clearIdentity: () async => fail('Uncertain marker must preserve keys'),
        signOut: () async {
          signOuts++;
        },
      );
      expect(signOuts, 1);
      expect(await marker.readAsString(), 'complete');
    });
  }

  test('failed iOS key deletion cannot complete the install reset', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await expectLater(
      AuthService.resetFreshIosInstall(
        prefs,
        installMarker: marker,
        hasLocalLibrary: () async => false,
        clearIdentity: () async =>
            throw PlatformException(code: 'keychain-locked'),
        signOut: () async => fail('Reset must stop before signing out'),
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(await marker.exists(), false);
    expect(prefs.getBool('has_launched_before'), isNot(true));
  });

  final successfulStates = [
    PostSignInState.idle,
    PostSignInState.running(PostSignInStage.identityValidation),
    PostSignInState.running(PostSignInStage.accountInitialization),
    PostSignInState.running(PostSignInStage.encryptionInitialization),
    PostSignInState.running(PostSignInStage.auxiliaryServices),
    PostSignInState.ready,
  ];

  test(
    'usable cached encryption remains on Home through successful startup',
    () {
      for (final e2eeStatus in [
        E2EEStatus.ready,
        E2EEStatus.verifyingInBackground,
      ]) {
        for (final postSignInState in successfulStates) {
          expect(
            resolveAuthenticatedStartupRoute(
              postSignInState: postSignInState,
              e2eeStatus: e2eeStatus,
            ),
            AuthenticatedStartupRoute.home,
            reason:
                '${e2eeStatus.name} should remain usable during '
                '${postSignInState.stage.name}',
          );
        }
      }
    },
  );

  test(
    'cold startup keeps one loading destination until encryption is usable',
    () {
      for (final e2eeStatus in [
        E2EEStatus.notInitialized,
        E2EEStatus.notSetUp,
      ]) {
        for (final postSignInState in successfulStates) {
          expect(
            resolveAuthenticatedStartupRoute(
              postSignInState: postSignInState,
              e2eeStatus: e2eeStatus,
            ),
            AuthenticatedStartupRoute.loading,
          );
        }
      }

      expect(
        resolveAuthenticatedStartupRoute(
          postSignInState: PostSignInState.running(
            PostSignInStage.auxiliaryServices,
          ),
          e2eeStatus: E2EEStatus.ready,
        ),
        AuthenticatedStartupRoute.home,
      );
    },
  );

  test('cloud startup failures cannot replace locally usable Home', () {
    for (final stage in [
      PostSignInStage.identityValidation,
      PostSignInStage.accountInitialization,
      PostSignInStage.encryptionInitialization,
    ]) {
      expect(
        resolveAuthenticatedStartupRoute(
          postSignInState: PostSignInState.recoverableFailure(
            stage,
            operation: 'test-operation',
          ),
          e2eeStatus: E2EEStatus.ready,
        ),
        AuthenticatedStartupRoute.home,
      );
    }
  });

  test(
    'confirmed key loss opens recovery while an uninitialized device can retry',
    () {
      for (final localState in [
        LocalEncryptionState.approvedKeyMissing,
        LocalEncryptionState.corrupt,
        LocalEncryptionState.missing,
      ]) {
        expect(
          resolveAuthenticatedStartupRoute(
            postSignInState: PostSignInState.idle,
            e2eeStatus: E2EEStatus.error,
            localState: localState,
          ),
          localState == LocalEncryptionState.missing
              ? AuthenticatedStartupRoute.recovery
              : AuthenticatedStartupRoute.accountRecovery,
        );
      }
    },
  );
  test('special encryption states retain their existing destinations', () {
    const expectedRoutes = {
      E2EEStatus.pendingApproval: AuthenticatedStartupRoute.pendingApproval,
      E2EEStatus.revoked: AuthenticatedStartupRoute.pendingApproval,
      E2EEStatus.needsRecovery: AuthenticatedStartupRoute.accountRecovery,
      E2EEStatus.error: AuthenticatedStartupRoute.recovery,
    };

    for (final entry in expectedRoutes.entries) {
      expect(
        resolveAuthenticatedStartupRoute(
          postSignInState: PostSignInState.idle,
          e2eeStatus: entry.key,
        ),
        entry.value,
      );
    }
  });
}
