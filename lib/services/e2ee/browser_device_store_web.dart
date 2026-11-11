import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'browser_device_store.dart'
    show BrowserIdentityConflict, OfflineGrantState;
export 'browser_device_store.dart'
    show BrowserIdentityConflict, OfflineGrantState;

const _store = 'devices';
const _deadline = Duration(seconds: 4);

// Independent, non-secret proof that this browser may reopen a particular
// saved identity offline. Removing an existing item needs no additional quota.
const _grantPrefix = 'better-keep.offline-grant.';

String newOfflineGrantId() => web.window.crypto.randomUUID();

OfflineGrantState offlineGrantState(String? id) {
  if (id == null) return OfflineGrantState.missing;
  try {
    return switch (web.window.localStorage.getItem('$_grantPrefix$id')) {
      '1' => OfflineGrantState.active,
      '0' => OfflineGrantState.revoked,
      _ => OfflineGrantState.missing,
    };
  } catch (_) {
    return OfflineGrantState.unavailable;
  }
}

void invalidateOfflineGrant(String id, {required bool revoked}) {
  // An ordinary key clear can follow a confirmed revocation. Preserve that
  // reason until IndexedDB has successfully retired the corresponding record.
  final state = offlineGrantState(id);
  if (state == OfflineGrantState.revoked ||
      state == OfflineGrantState.missing) {
    return;
  }
  if (revoked) {
    try {
      web.window.localStorage.setItem('$_grantPrefix$id', '0');
      return;
    } catch (_) {
      // Removal needs no additional quota. Missing proof still denies access.
    }
  }
  retireOfflineGrant(id);
}

void retireOfflineGrant(String? id) {
  if (id != null) web.window.localStorage.removeItem('$_grantPrefix$id');
}

Future<web.IDBDatabase> _open() {
  final ready = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open('better-keep.device-trust.v1', 1);
  void unavailable() {
    if (!ready.isCompleted) {
      ready.completeError(StateError('Browser device storage unavailable'));
    }
  }

  final timeout = Timer(_deadline, unavailable);
  request.onblocked = ((web.Event _) => unavailable()).toJS;
  request.onupgradeneeded = ((web.Event _) {
    (request.result as web.IDBDatabase).createObjectStore(_store);
  }).toJS;
  request.onsuccess = ((web.Event _) {
    final db = request.result as web.IDBDatabase;
    if (ready.isCompleted) {
      db.close();
    } else {
      ready.complete(db);
    }
  }).toJS;
  request.onerror = ((web.Event _) => unavailable()).toJS;
  return ready.future.whenComplete(timeout.cancel);
}

JSObject _algorithm(String scope, String uid, JSUint8Array iv) => JSObject()
  ..['name'] = 'AES-GCM'.toJS
  ..['iv'] = iv
  ..['additionalData'] = utf8
      .encode(jsonEncode(['better-keep/device/v1', scope, uid]))
      .toJS;

int _revision(JSObject? record) =>
    record == null ? 0 : (record['revision'] as JSNumber).toDartInt;

Future<(int, String?)> readDeviceIdentity(String scope, String uid) async {
  final db = await _open();
  try {
    final request = db
        .transaction(_store.toJS)
        .objectStore(_store)
        .get(scope.toJS);
    final read = Completer<JSObject?>();
    request.onsuccess = ((web.Event _) {
      final record = request.result as JSObject?;
      // An activated grant and this reservation can coexist only if a
      // publication transaction aborted. This read holds an IndexedDB lock.
      try {
        retireOfflineGrant((record?['pendingGrant'] as JSString?)?.toDart);
      } catch (_) {
        // A later read or write retries when Web Storage is accessible.
      }
      read.complete(record);
    }).toJS;
    request.onerror = ((web.Event _) => read.completeError(
      StateError('Browser device read failed'),
    )).toJS;
    final record = await read.future.timeout(_deadline);
    final revision = _revision(record);
    if (record == null || (record['uid'] as JSString?)?.toDart != uid) {
      return (revision, null);
    }
    final bytes = await web.window.crypto.subtle
        .decrypt(
          _algorithm(scope, uid, record['iv'] as JSUint8Array),
          record['key'] as web.CryptoKey,
          record['data'] as JSArrayBuffer,
        )
        .toDart
        .timeout(_deadline);
    return (
      revision,
      utf8.decode((bytes as JSArrayBuffer).toDart.asUint8List()),
    );
  } finally {
    db.close();
  }
}

// Clearing writes a revision tombstone. A tab that began approval before
// sign-out cannot put its obsolete identity back in the cleared slot.
Future<int> writeDeviceIdentity(
  String scope,
  String uid,
  String? identity, {
  required int? expectedRevision,
  required bool Function() isCurrent,
  void Function()? beforeClear,
  String? grantToActivate,
}) async {
  final next = JSObject();
  if (identity != null) {
    final crypto = web.window.crypto;
    final key =
        (await crypto.subtle
                .generateKey(
                  JSObject()
                    ..['name'] = 'AES-GCM'.toJS
                    ..['length'] = 256.toJS,
                  false,
                  ['encrypt'.toJS, 'decrypt'.toJS].toJS,
                )
                .toDart
                .timeout(_deadline))
            as web.CryptoKey;
    final iv = Uint8List(12).toJS;
    crypto.getRandomValues(iv);
    next['data'] = await crypto.subtle
        .encrypt(_algorithm(scope, uid, iv), key, utf8.encode(identity).toJS)
        .toDart
        .timeout(_deadline);
    next['iv'] = iv;
    next['key'] = key;
    next['uid'] = uid.toJS;
  }
  final db = await _open();
  Future<int> commit({bool reserveGrant = false}) async {
    final finished = Completer<int>();
    final txn = db.transaction(_store.toJS, 'readwrite');
    final store = txn.objectStore(_store);
    final get = store.get(scope.toJS);
    var revision = 0;
    var conflict = false;
    get.onsuccess = ((web.Event _) {
      try {
        final stored = get.result as JSObject?;
        revision = _revision(stored);
        final storedOwner = (stored?['uid'] as JSString?)?.toDart;
        // A delayed logout in one account must leave another account's newly
        // approved identity alone. Interrupted logout may have no owner left.
        if (identity == null &&
            expectedRevision == null &&
            uid.isNotEmpty &&
            storedOwner != null &&
            storedOwner != uid) {
          return;
        }
        if (!isCurrent()) {
          txn.abort();
          return;
        }
        if (expectedRevision != null && expectedRevision != revision) {
          // This particular grant was already retired. A late revocation must
          // neither erase its replacement nor adopt the new write revision.
          if (identity == null) {
            revision = expectedRevision;
            return;
          }
          conflict = true;
          txn.abort();
          return;
        }
        final reserved = (stored?['pendingGrant'] as JSString?)?.toDart;
        if (reserveGrant) {
          // Persist a pointer before activating Web Storage so the next
          // transaction can retire an interrupted grant without losing keys.
          retireOfflineGrant(reserved);
          final reservation =
              stored ?? (JSObject()..['revision'] = revision.toJS);
          reservation['pendingGrant'] = grantToActivate!.toJS;
          store.put(reservation, scope.toJS);
          return;
        }
        if (grantToActivate != null) {
          if (reserved != grantToActivate) {
            conflict = true;
            txn.abort();
            return;
          }
          web.window.localStorage.setItem('$_grantPrefix$grantToActivate', '1');
        } else {
          retireOfflineGrant(reserved);
        }
        // Other tabs cannot advance this revision during the write transaction.
        if (identity == null) beforeClear?.call();
        next['revision'] = (++revision).toJS;
        store.put(next, scope.toJS);
      } catch (_) {
        txn.abort();
      }
    }).toJS;
    txn.oncomplete = ((web.Event _) => finished.complete(revision)).toJS;
    txn.onabort = ((web.Event _) => finished.completeError(
      conflict
          ? const BrowserIdentityConflict()
          : StateError('Browser device write was not committed'),
    )).toJS;
    return await finished.future.timeout(
      _deadline,
      onTimeout: () {
        txn.abort();
        throw TimeoutException('Browser device transaction timed out');
      },
    );
  }

  try {
    if (grantToActivate != null) await commit(reserveGrant: true);
    return await commit();
  } finally {
    db.close();
  }
}
