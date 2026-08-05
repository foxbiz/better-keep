import 'dart:async';

import 'package:better_keep/services/oauth_transaction.dart';
import 'package:better_keep/services/recovered_oauth_sign_in_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('waits for app services before authenticating and finalizing', () async {
    final harness = _RecoveryHarness();
    final readiness = Completer<void>();

    final completion = harness.coordinator.completeCallback(
      transaction: _transaction(),
      completionCode: 'completion-code',
      appServicesReady: readiness.future,
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.events, isEmpty);

    harness.events.add('ready');
    readiness.complete();
    await completion;

    expect(harness.events, [
      'ready',
      'verifying:true',
      'redeem:completion-code',
      'authenticate:custom-token',
      'finalize:signed-user:github',
      'verifying:false',
      'remove:transaction-id',
    ]);
  });

  test('hands an in-process callback back without running recovery', () async {
    final harness = _RecoveryHarness();
    final readiness = Completer<void>();

    await harness.coordinator.completeCallback(
      transaction: _transaction(),
      completionCode: 'completion-code',
      appServicesReady: readiness.future,
      completeInFlight: () => harness.events.add('in-flight'),
    );

    expect(harness.events, ['in-flight']);
  });

  test('rejects a restarted non-sign-in transaction and cleans it', () async {
    final harness = _RecoveryHarness();

    await expectLater(
      harness.coordinator.completeCallback(
        transaction: _transaction(mode: 'link'),
        completionCode: 'completion-code',
        appServicesReady: Future.value(),
      ),
      throwsA(
        isA<RecoveredOAuthSignInException>().having(
          (error) => error.code,
          'code',
          'invalid-transaction-mode',
        ),
      ),
    );

    expect(harness.events, ['verifying:false', 'remove:transaction-id']);
  });

  test('rejects custom-token authentication without a user', () async {
    final harness = _RecoveryHarness(returnUser: false);

    await expectLater(
      harness.coordinator.completeCallback(
        transaction: _transaction(),
        completionCode: 'completion-code',
        appServicesReady: Future.value(),
      ),
      throwsA(
        isA<RecoveredOAuthSignInException>().having(
          (error) => error.code,
          'code',
          'missing-user',
        ),
      ),
    );

    expect(harness.events, [
      'verifying:true',
      'redeem:completion-code',
      'authenticate:custom-token',
      'verifying:false',
      'remove:transaction-id',
    ]);
  });

  for (final stage in _FailureStage.values) {
    test(
      '${stage.name} failure resets state, cleans up, and propagates',
      () async {
        final harness = _RecoveryHarness(failureStage: stage);

        await expectLater(
          harness.coordinator.completeCallback(
            transaction: _transaction(),
            completionCode: 'completion-code',
            appServicesReady: stage == _FailureStage.readiness
                ? Future<void>.error(StateError(stage.name))
                : Future.value(),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              stage.name,
            ),
          ),
        );

        expect(harness.events, contains('verifying:false'));
        expect(harness.events.where((event) => event.startsWith('remove:')), [
          'remove:transaction-id',
        ]);
      },
    );
  }

  test(
    'cleanup failure does not mask the primary authentication error',
    () async {
      final harness = _RecoveryHarness(
        failureStage: _FailureStage.authentication,
        failCleanup: true,
      );

      await expectLater(
        harness.coordinator.completeCallback(
          transaction: _transaction(),
          completionCode: 'completion-code',
          appServicesReady: Future.value(),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            _FailureStage.authentication.name,
          ),
        ),
      );

      expect(harness.secondaryFailures, hasLength(1));
      expect(harness.secondaryFailures.single, isA<StateError>());
    },
  );
}

OAuthTransaction _transaction({String mode = 'signin'}) => OAuthTransaction(
  id: 'transaction-id',
  verifier: 'verifier',
  provider: 'github',
  mode: mode,
  createdAt: DateTime.utc(2030),
);

enum _FailureStage { readiness, redemption, authentication, finalization }

class _RecoveryHarness {
  _RecoveryHarness({
    this.failureStage,
    this.returnUser = true,
    this.failCleanup = false,
  });

  final _FailureStage? failureStage;
  final bool returnUser;
  final bool failCleanup;
  final events = <String>[];
  final secondaryFailures = <Object>[];

  late final coordinator = RecoveredOAuthSignInCoordinator<String>(
    redeemCompletion: (completionCode, transaction) async {
      events.add('redeem:$completionCode');
      if (failureStage == _FailureStage.redemption) {
        throw StateError(failureStage!.name);
      }
      return 'custom-token';
    },
    authenticateWithCustomToken: (customToken) async {
      events.add('authenticate:$customToken');
      if (failureStage == _FailureStage.authentication) {
        throw StateError(failureStage!.name);
      }
      return returnUser ? 'signed-user' : null;
    },
    finalizeSignIn: (user, provider) async {
      events.add('finalize:$user:$provider');
      if (failureStage == _FailureStage.finalization) {
        throw StateError(failureStage!.name);
      }
    },
    removeTransaction: (transactionId) async {
      events.add('remove:$transactionId');
      if (failCleanup) throw StateError('cleanup');
    },
    setVerificationState: (value) => events.add('verifying:$value'),
    reportSecondaryFailure: (error, stackTrace) {
      secondaryFailures.add(error);
    },
  );
}
