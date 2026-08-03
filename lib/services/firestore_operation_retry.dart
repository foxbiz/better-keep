import 'dart:async';

import 'package:firebase_core/firebase_core.dart';

const List<Duration> firestoreRetryDelays = [
  Duration(milliseconds: 250),
  Duration(seconds: 1),
  Duration(seconds: 2),
];

const Set<String> transientFirestoreErrorCodes = {
  'unavailable',
  'deadline-exceeded',
  'aborted',
};

typedef FirestoreRetryDelay = Future<void> Function(Duration duration);

bool isTransientFirestoreFailure(Object error) {
  return error is FirebaseException &&
      transientFirestoreErrorCodes.contains(error.code);
}

/// Retries only Firestore failures which are documented as transient.
///
/// There are four total attempts: the initial call followed by the fixed
/// 250 ms, 1 second, and 2 second retry delays.
Future<T> retryTransientFirestoreOperation<T>(
  Future<T> Function() operation, {
  FirestoreRetryDelay delay = Future<void>.delayed,
  void Function(Object error, int nextAttempt, Duration delay)? onRetry,
}) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return await operation();
    } catch (error) {
      if (!isTransientFirestoreFailure(error) ||
          attempt >= firestoreRetryDelays.length) {
        rethrow;
      }
      final retryDelay = firestoreRetryDelays[attempt];
      onRetry?.call(error, attempt + 2, retryDelay);
      await delay(retryDelay);
    }
  }
}

class FirestoreDocumentFetchException implements Exception {
  const FirestoreDocumentFetchException({
    required this.resource,
    required this.operation,
    required this.cause,
  });

  final String resource;
  final String operation;
  final Object cause;

  String? get firebaseCode =>
      cause is FirebaseException ? (cause as FirebaseException).code : null;

  @override
  String toString() {
    final code = firebaseCode;
    return 'Failed to fetch $resource during $operation'
        '${code == null ? '' : ' (Firestore: $code)'}: $cause';
  }
}
