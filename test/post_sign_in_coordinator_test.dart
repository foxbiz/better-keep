import 'package:better_keep/services/post_sign_in_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs required stages and auxiliary services in order', () async {
    final harness = _Harness();

    final result = await harness.coordinator.run();

    expect(result, PostSignInResult.ready);
    expect(harness.events, [
      'identity',
      'account',
      'encryption',
      'auxiliary-one',
      'auxiliary-two',
      'clear-progress',
    ]);
    expect(harness.states.last, PostSignInState.ready);
    expect(harness.signOutCount, 0);
  });

  for (final stage in [
    PostSignInStage.identityValidation,
    PostSignInStage.accountInitialization,
    PostSignInStage.encryptionInitialization,
  ]) {
    test('${stage.name} transient failure preserves the session', () async {
      final harness = _Harness(failingStage: stage);

      final result = await harness.coordinator.run();

      expect(result, PostSignInResult.recoverableFailure);
      expect(harness.signOutCount, 0);
      expect(harness.clearProgressCount, 0);
      expect(
        harness.states.last,
        PostSignInState.recoverableFailure(
          stage,
          operation: harness.operationNameFor(stage),
        ),
      );
    });
  }

  test('definitive identity failure signs out and propagates', () async {
    final error = StateError('revoked');
    final harness = _Harness(
      failingStage: PostSignInStage.identityValidation,
      failure: error,
      fatalIdentityFailure: true,
    );

    await expectLater(harness.coordinator.run(), throwsA(same(error)));

    expect(harness.signOutCount, 1);
    expect(harness.states.last, PostSignInState.idle);
    expect(harness.clearProgressCount, 0);
  });

  test('an auxiliary failure is logged and does not block readiness', () async {
    final harness = _Harness(failingAuxiliary: 'auxiliary-one');

    final result = await harness.coordinator.run();

    expect(result, PostSignInResult.ready);
    expect(
      harness.events,
      containsAllInOrder(['auxiliary-one', 'auxiliary-two']),
    );
    expect(harness.failures.single.operation, 'auxiliary-one');
    expect(harness.states.last, PostSignInState.ready);
  });

  test('all auxiliary failures are isolated from one another', () async {
    final harness = _Harness(failAllAuxiliaries: true);

    final result = await harness.coordinator.run();

    expect(result, PostSignInResult.ready);
    expect(harness.failures.map((failure) => failure.operation), [
      'auxiliary-one',
      'auxiliary-two',
    ]);
    expect(harness.clearProgressCount, 1);
  });

  test('a later run can recover after a transient failure', () async {
    final harness = _Harness(
      failingStage: PostSignInStage.encryptionInitialization,
    );

    expect(
      await harness.coordinator.run(),
      PostSignInResult.recoverableFailure,
    );
    harness.failingStage = null;

    expect(await harness.coordinator.run(), PostSignInResult.ready);
    expect(harness.signOutCount, 0);
    expect(harness.states.last, PostSignInState.ready);
  });

  test('stops cleanly when the authenticated session changes', () async {
    final harness = _Harness();
    harness.changeSessionAfterIdentity = true;

    final result = await harness.coordinator.run();

    expect(result, PostSignInResult.sessionChanged);
    expect(harness.events, ['identity']);
    expect(harness.states.last, PostSignInState.idle);
  });
}

typedef _Failure = ({PostSignInStage stage, String operation, Object error});

class _Harness {
  _Harness({
    this.failingStage,
    this.failure = const _TestFailure(),
    this.fatalIdentityFailure = false,
    this.failingAuxiliary,
    this.failAllAuxiliaries = false,
  });

  PostSignInStage? failingStage;
  final Object failure;
  final bool fatalIdentityFailure;
  final String? failingAuxiliary;
  final bool failAllAuxiliaries;
  bool sessionCurrent = true;
  bool changeSessionAfterIdentity = false;
  int signOutCount = 0;
  int clearProgressCount = 0;
  final events = <String>[];
  final states = <PostSignInState>[];
  final failures = <_Failure>[];

  String operationNameFor(PostSignInStage stage) => switch (stage) {
    PostSignInStage.identityValidation => 'validate-identity',
    PostSignInStage.accountInitialization => 'initialize-account',
    PostSignInStage.encryptionInitialization => 'initialize-encryption',
    _ => throw ArgumentError.value(stage),
  };

  late final coordinator = PostSignInCoordinator(
    validateIdentity: PostSignInOperation('validate-identity', () async {
      events.add('identity');
      _throwFor(PostSignInStage.identityValidation);
      if (changeSessionAfterIdentity) sessionCurrent = false;
    }),
    initializeAccount: PostSignInOperation('initialize-account', () async {
      events.add('account');
      _throwFor(PostSignInStage.accountInitialization);
    }),
    initializeEncryption: PostSignInOperation(
      'initialize-encryption',
      () async {
        events.add('encryption');
        _throwFor(PostSignInStage.encryptionInitialization);
      },
    ),
    auxiliaryServices: [
      PostSignInOperation(
        'auxiliary-one',
        () => _runAuxiliary('auxiliary-one'),
      ),
      PostSignInOperation(
        'auxiliary-two',
        () => _runAuxiliary('auxiliary-two'),
      ),
    ],
    isFatalIdentityFailure: (_) => fatalIdentityFailure,
    isSessionCurrent: () => sessionCurrent,
    signOut: () async {
      signOutCount++;
    },
    clearSignInProgress: () async {
      clearProgressCount++;
      events.add('clear-progress');
    },
    onStateChanged: states.add,
    reportFailure: (stage, operation, error, stackTrace) {
      failures.add((stage: stage, operation: operation, error: error));
    },
  );

  void _throwFor(PostSignInStage stage) {
    if (failingStage == stage) throw failure;
  }

  Future<void> _runAuxiliary(String name) async {
    events.add(name);
    if (failAllAuxiliaries || failingAuxiliary == name) throw failure;
  }
}

class _TestFailure implements Exception {
  const _TestFailure();
}
