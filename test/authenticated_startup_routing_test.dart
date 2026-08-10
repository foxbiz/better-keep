import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:better_keep/utils/authenticated_startup_routing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('required-stage failures retain the recovery destination', () {
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
        AuthenticatedStartupRoute.recovery,
      );
    }
  });

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
