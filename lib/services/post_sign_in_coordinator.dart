import 'dart:async';

import 'package:flutter/foundation.dart';

enum PostSignInStage {
  idle,
  identityValidation,
  accountInitialization,
  encryptionInitialization,
  auxiliaryServices,
  complete,
}

enum PostSignInStatus { idle, running, ready, recoverableFailure }

@immutable
class PostSignInState {
  const PostSignInState._({
    required this.status,
    required this.stage,
    this.failedOperation,
  });

  static const idle = PostSignInState._(
    status: PostSignInStatus.idle,
    stage: PostSignInStage.idle,
  );

  static const ready = PostSignInState._(
    status: PostSignInStatus.ready,
    stage: PostSignInStage.complete,
  );

  factory PostSignInState.running(PostSignInStage stage) =>
      PostSignInState._(status: PostSignInStatus.running, stage: stage);

  factory PostSignInState.recoverableFailure(
    PostSignInStage stage, {
    required String operation,
  }) => PostSignInState._(
    status: PostSignInStatus.recoverableFailure,
    stage: stage,
    failedOperation: operation,
  );

  final PostSignInStatus status;
  final PostSignInStage stage;

  /// Stable diagnostic label only. User-visible and sensitive error details do
  /// not flow through presentation state.
  final String? failedOperation;

  bool get isRunning => status == PostSignInStatus.running;
  bool get hasRecoverableFailure =>
      status == PostSignInStatus.recoverableFailure;

  @override
  bool operator ==(Object other) =>
      other is PostSignInState &&
      other.status == status &&
      other.stage == stage &&
      other.failedOperation == failedOperation;

  @override
  int get hashCode => Object.hash(status, stage, failedOperation);
}

enum PostSignInResult { ready, recoverableFailure, sessionChanged }

class PostSignInOperation {
  const PostSignInOperation(this.name, this.run);

  final String name;
  final Future<void> Function() run;
}

typedef PostSignInFailureReporter =
    FutureOr<void> Function(
      PostSignInStage stage,
      String operation,
      Object error,
      StackTrace stackTrace,
    );

/// Runs authenticated startup without treating transient service failures as
/// authentication failures.
class PostSignInCoordinator {
  const PostSignInCoordinator({
    required this.validateIdentity,
    required this.initializeAccount,
    required this.initializeEncryption,
    required this.auxiliaryServices,
    required this.isFatalIdentityFailure,
    required this.isSessionCurrent,
    required this.signOut,
    required this.clearSignInProgress,
    required this.onStateChanged,
    required this.reportFailure,
  });

  final PostSignInOperation validateIdentity;
  final PostSignInOperation initializeAccount;
  final PostSignInOperation initializeEncryption;
  final List<PostSignInOperation> auxiliaryServices;
  final bool Function(Object error) isFatalIdentityFailure;
  final bool Function() isSessionCurrent;
  final Future<void> Function() signOut;
  final Future<void> Function() clearSignInProgress;
  final ValueChanged<PostSignInState> onStateChanged;
  final PostSignInFailureReporter reportFailure;

  Future<PostSignInResult> run() async {
    final identityResult = await _runRequiredOperation(
      PostSignInStage.identityValidation,
      validateIdentity,
      allowFatalIdentityFailure: true,
    );
    if (identityResult != null) return identityResult;

    final accountResult = await _runRequiredOperation(
      PostSignInStage.accountInitialization,
      initializeAccount,
    );
    if (accountResult != null) return accountResult;

    final encryptionResult = await _runRequiredOperation(
      PostSignInStage.encryptionInitialization,
      initializeEncryption,
    );
    if (encryptionResult != null) return encryptionResult;

    onStateChanged(PostSignInState.running(PostSignInStage.auxiliaryServices));
    for (final service in auxiliaryServices) {
      if (!isSessionCurrent()) return _handleSessionChanged();
      try {
        await service.run();
      } catch (error, stackTrace) {
        await reportFailure(
          PostSignInStage.auxiliaryServices,
          service.name,
          error,
          stackTrace,
        );
      }
    }

    if (!isSessionCurrent()) return _handleSessionChanged();
    try {
      await clearSignInProgress();
    } catch (error, stackTrace) {
      await reportFailure(
        PostSignInStage.auxiliaryServices,
        'clear-sign-in-progress',
        error,
        stackTrace,
      );
    }

    onStateChanged(PostSignInState.ready);
    return PostSignInResult.ready;
  }

  Future<PostSignInResult?> _runRequiredOperation(
    PostSignInStage stage,
    PostSignInOperation operation, {
    bool allowFatalIdentityFailure = false,
  }) async {
    if (!isSessionCurrent()) return _handleSessionChanged();
    onStateChanged(PostSignInState.running(stage));

    try {
      await operation.run();
    } catch (error, stackTrace) {
      await reportFailure(stage, operation.name, error, stackTrace);
      if (allowFatalIdentityFailure && isFatalIdentityFailure(error)) {
        try {
          await signOut();
        } catch (signOutError, signOutStackTrace) {
          await reportFailure(
            stage,
            'sign-out-after-fatal-identity-failure',
            signOutError,
            signOutStackTrace,
          );
        }
        onStateChanged(PostSignInState.idle);
        Error.throwWithStackTrace(error, stackTrace);
      }

      onStateChanged(
        PostSignInState.recoverableFailure(stage, operation: operation.name),
      );
      return PostSignInResult.recoverableFailure;
    }

    if (!isSessionCurrent()) return _handleSessionChanged();
    return null;
  }

  PostSignInResult _handleSessionChanged() {
    onStateChanged(PostSignInState.idle);
    return PostSignInResult.sessionChanged;
  }
}
