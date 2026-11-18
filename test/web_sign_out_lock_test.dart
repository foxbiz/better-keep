@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:better_keep/services/sign_out_lock_web.dart';
import 'package:better_keep/services/web_release.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

@JS('Object.defineProperty')
external void _defineProperty(
  JSObject target,
  String name,
  JSObject descriptor,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'without Web Locks, single-tab sign-out runs and propagates failures',
    () async {
      final navigator = web.window.navigator;
      _defineProperty(
        navigator,
        'locks',
        {'value': null, 'configurable': true}.jsify() as JSObject,
      );
      addTearDown(() => navigator.delete('locks'.toJS));
      var calls = 0;
      expect(
        await withSignOutLock('fixture', () async {
          calls++;
        }),
        true,
      );
      expect(calls, 1);
      await expectLater(
        withSignOutLock('fixture', () async {
          throw StateError('failed');
        }),
        throwsStateError,
      );
    },
  );

  test(
    'another browser window cannot start or queue a conflicting sign-out',
    () async {
      final frame = web.HTMLIFrameElement();
      web.document.body!.appendChild(frame);
      addTearDown(() => frame.remove());
      final entered = Completer<void>();
      final release = Completer<void>();
      final scope = 'logout-test-${DateTime.now().microsecondsSinceEpoch}';
      final owner = frame.contentWindow!.navigator.locks
          .request(
            'better-keep.sign-out.$webStoragePrefix$scope',
            ((web.Lock lock) {
              entered.complete();
              return release.future.toJS;
            }).toJS,
          )
          .toDart;
      var ran = false;
      try {
        await entered.future;
        expect(
          await withSignOutLock(scope, () async {
            ran = true;
          }),
          false,
        );
        expect(ran, false);
      } finally {
        release.complete();
        await owner;
      }
      // A denied request must never start later, after the other tab signs out.
      expect(ran, false);
      await expectLater(
        withSignOutLock(scope, () async {
          throw StateError('failed');
        }),
        throwsStateError,
      );
      expect(
        await withSignOutLock(scope, () async {
          ran = true;
        }),
        true,
      );
      expect(ran, true);
    },
  );

  test(
    'a competing window cannot reload until the owner releases the lock',
    () async {
      // Keep the runner in the owner tab while a second real tab navigates.
      final url = web.URL.createObjectURL(
        web.Blob(
          ['<!doctype html><title>Fresh library</title>'.toJS].toJS,
          web.BlobPropertyBag(type: 'text/html'),
        ),
      );
      final tab = web.window.open(url, '_blank')!;
      addTearDown(() {
        tab.close();
        web.URL.revokeObjectURL(url);
      });
      Future<void> waitForFreshDocument() async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          if (tab.document.title == 'Fresh library') return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('The second tab did not load a fresh document');
      }

      await waitForFreshDocument();
      tab.document.title = 'Old library';
      final scope = 'reload-${DateTime.now().microsecondsSinceEpoch}';
      final entered = Completer<void>();
      final release = Completer<void>();
      final owner = withSignOutLock(scope, () {
        entered.complete();
        return release.future;
      });
      try {
        await entered.future;
        await expectLater(
          refreshAfterExternalSignOut(scope, window: tab),
          throwsA(isA<TimeoutException>()),
        );
        expect(tab.document.title, 'Old library');
      } finally {
        release.complete();
        await owner;
      }
      final stopped = expectLater(
        refreshAfterExternalSignOut(scope, window: tab),
        throwsA(isA<TimeoutException>()),
      );
      await waitForFreshDocument();
      expect(tab.document.title, 'Fresh library');
      // In this test the caller lives outside the reloaded tab. Even so the
      // old operation must time out rather than return to account cleanup.
      await stopped;
    },
  );
}
