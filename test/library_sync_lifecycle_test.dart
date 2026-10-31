import 'dart:async';

import 'package:better_keep/services/external_sync/library_sync_lifecycle.dart';
import 'package:better_keep/services/external_sync/library_sync_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'replacement invalidates synchronously and waits for old work to drain',
    () async {
      final lifecycle = LibrarySyncLifecycle();
      final release = Completer<void>();
      final old = _Session()..drain = release.future;
      late bool Function() oldCurrent;
      await lifecycle.replace(('account', 'key-a'), (current) async {
        oldCurrent = current;
        return old;
      });
      final next = _Session();
      var created = false;
      final replacing = lifecycle.replace(('account', 'key-b'), (
        current,
      ) async {
        created = true;
        return next;
      });
      expect(old.retired, isTrue);
      expect(oldCurrent(), isFalse);
      expect(lifecycle.session, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(created, isFalse);
      release.complete();
      await replacing;
      expect(old.closed, isTrue);
      expect(lifecycle.session, next);
      await lifecycle.stop();
      expect(next.closed, isTrue);
      lifecycle.dispose();
    },
  );

  test('logout during initialization drains the late candidate without attaching it', () async {
    final lifecycle = LibrarySyncLifecycle();
    final pending = Completer<LibrarySyncSession>();
    final started = Completer<void>();
    late bool Function() current;
    final creating = lifecycle.replace('account', (guard) {
      current = guard;
      started.complete();
      return pending.future;
    });
    await started.future;
    final stopping = lifecycle.stop();
    expect(current(), isFalse);
    final candidate = _Session();
    pending.complete(candidate);
    await Future.wait([creating, stopping]);
    expect(candidate.retired, isTrue);
    expect(candidate.closed, isTrue);
    expect(lifecycle.session, isNull);
    lifecycle.dispose();
  });

  test(
    'rapid account changes create only the latest queued identity',
    () async {
      final lifecycle = LibrarySyncLifecycle();
      final release = Completer<void>();
      final initial = _Session()..drain = release.future;
      await lifecycle.replace('a', (_) async => initial);
      var bCreated = false;
      final b = lifecycle.replace('b', (_) async {
        bCreated = true;
        return _Session();
      });
      final cSession = _Session();
      final c = lifecycle.replace('c', (_) async => cSession);
      release.complete();
      await Future.wait([b, c]);
      expect(bCreated, isFalse);
      expect(lifecycle.session, cSession);
      await lifecycle.stop();
      lifecycle.dispose();
    },
  );

  test(
    'same identity coalesces initialization and failed creation can retry',
    () async {
      final lifecycle = LibrarySyncLifecycle();
      var calls = 0;
      final release = Completer<LibrarySyncSession>();
      Future<LibrarySyncSession> create(bool Function() _) {
        calls++;
        return release.future;
      }

      final first = lifecycle.replace('account', create);
      final duplicate = lifecycle.replace('account', create);
      expect(identical(first, duplicate), isTrue);
      final rejected = expectLater(first, throwsStateError);
      release.completeError(StateError('synthetic initialization failure'));
      await rejected;
      expect(calls, 1);
      expect(lifecycle.failure, isNotNull);
      final recovered = _Session();
      await lifecycle.replace('account', (_) async => recovered);
      expect(lifecycle.session, recovered);
      expect(lifecycle.failure, isNull);
      await lifecycle.stop();
      lifecycle.dispose();
    },
  );

  test(
    'failed drain prevents new initialization and is retried before cleanup',
    () async {
      final lifecycle = LibrarySyncLifecycle();
      final old = _Session()..failClose = true;
      await lifecycle.replace('a', (_) async => old);
      var created = false;
      await expectLater(
        lifecycle.replace('b', (_) async {
          created = true;
          return _Session();
        }),
        throwsStateError,
      );
      expect(created, isFalse);
      expect(lifecycle.session, isNull);
      old.failClose = false;
      await lifecycle.stop();
      expect(old.closed, isTrue);
      lifecycle.dispose();
    },
  );
}

class _Session extends ChangeNotifier implements LibrarySyncSession {
  bool retired = false, closed = false, failClose = false;
  Future<void>? drain;
  @override
  void retire() {
    retired = true;
  }

  @override
  Future<void> close() async {
    retire();
    await drain;
    if (failClose) throw StateError('synthetic drain failure');
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
