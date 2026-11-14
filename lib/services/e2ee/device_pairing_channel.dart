import 'dart:async';

import 'package:flutter/foundation.dart';

import 'device_pairing_code.dart';
import 'device_verification.dart';

/// Implementations must bind every read/write to the same pending request and
/// account session. [change] is atomic, and its callback may be retried.
abstract interface class PairingCodeMailbox {
  Future<Map<String, dynamic>?> read();
  Stream<Map<String, dynamic>?> watch();
  Future<void> change(
    Map<String, dynamic>? Function(Map<String, dynamic>? current) update,
  );
}

enum PairingCodeState { waiting, connecting, shared, unavailable }

/// Owns the pending device's in-memory code and attempt budget. A new session
/// requires an explicit local user action, never a server-supplied retry flag.
class PendingPairingCode extends ChangeNotifier {
  PendingPairingCode._(this._host, this._mailbox, this._isCurrent);
  PairingCodeHost _host;
  final PairingCodeMailbox _mailbox;
  final bool Function() _isCurrent;
  StreamSubscription<Map<String, dynamic>?>? _subscription;
  Timer? _timer;
  Timer? _handoffTimer;
  bool _closed = false;
  bool _processing = false;
  Map<String, dynamic>? _queuedValue;
  bool _hasQueuedValue = false;
  PairingCodeState _state = PairingCodeState.waiting;
  PairingCodeState get state => _state;
  bool get handoffInProgress =>
      state == PairingCodeState.connecting || state == PairingCodeState.shared;
  String get code => _host.code;
  DeviceVerificationRequest get request => _host.request;

  static Future<PendingPairingCode> start(
    DeviceVerificationRequest request,
    PairingCodeMailbox mailbox, {
    required bool Function() isCurrent,
    Duration handoffTimeout = const Duration(seconds: 60),
  }) async {
    final session = PendingPairingCode._(
      await createPairingCodeHost(request),
      mailbox,
      isCurrent,
    );
    try {
      session._requireCurrent();
      await mailbox.change((_) {
        session._requireCurrent();
        return {'offer': session._host.offer};
      });
      session._requireCurrent();
      session._subscription = mailbox.watch().listen(
        (value) => unawaited(session._receive(value)),
        onError: (Object _) => session.close(),
      );
      session._timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!isCurrent() ||
            !request.isValidAt(DateTime.now()) ||
            (session._state != PairingCodeState.shared &&
                !session._processing &&
                !session._host.isValid)) {
          session.close();
        }
      });
      session._handoffTimeout = handoffTimeout;
      return session;
    } catch (_) {
      session.dispose();
      rethrow;
    }
  }

  Duration _handoffTimeout = const Duration(seconds: 60);

  void _requireCurrent() {
    if (_closed || !_isCurrent()) throw StateError('Pairing session ended');
    request.requireValid(DateTime.now());
  }

  Future<void> _receive(Map<String, dynamic>? value) async {
    if (_closed || state == PairingCodeState.shared) return;
    if (_processing) {
      _queuedValue = value;
      _hasQueuedValue = true;
      return;
    }
    if (!_isCurrent()) {
      close();
      return;
    }
    final offerId = _host.offer['id'];
    if (value?['offer'] is! Map || (value!['offer'] as Map)['id'] != offerId) {
      close();
      return;
    }
    if (!value.containsKey('response')) return;
    _processing = true;
    _state = PairingCodeState.connecting;
    notifyListeners();
    try {
      final raw = value['response'];
      final response = raw is Map<String, dynamic>
          ? raw
          : <String, dynamic>{'id': offerId};
      // An invalid/mismatched response still consumes this offer's attempt.
      final answered = await answerPairingCode(_host, {
        ...response,
        'id': offerId,
      });
      if (_closed || !_isCurrent()) {
        answered.$1.close();
        return;
      }
      _host = answered.$1;
      final result = answered.$2;
      _requireCurrent();
      await _mailbox.change((current) {
        _requireCurrent();
        if (current?['offer'] is! Map ||
            (current!['offer'] as Map)['id'] != offerId) {
          throw StateError('Pairing offer changed');
        }
        if (result != null) return {...current, 'result': result};
        if (!_host.isValid) return {'locked': true};
        return {'offer': _host.offer};
      });
      _requireCurrent();
      _state = result != null
          ? PairingCodeState.shared
          : _host.isValid
          ? PairingCodeState.waiting
          : PairingCodeState.unavailable;
      if (_state == PairingCodeState.shared) {
        // UI recovery timeout, not revocation of the already shared secret.
        // Explicit retry regenerates the request and invalidates that handoff.
        _handoffTimer = Timer(_handoffTimeout, close);
      }
      if (_state == PairingCodeState.unavailable) close();
    } catch (_) {
      // Do not replay a consumed SRP ephemeral after a failed network write.
      close();
    } finally {
      _processing = false;
      if (!_closed) notifyListeners();
      // A retry may arrive before the preceding offer write is acknowledged.
      if (_hasQueuedValue) {
        final queued = _queuedValue;
        _queuedValue = null;
        _hasQueuedValue = false;
        unawaited(_receive(queued));
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _host.close();
    _timer?.cancel();
    _handoffTimer?.cancel();
    unawaited(_subscription?.cancel());
    _state = PairingCodeState.unavailable;
    notifyListeners();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}

/// The trusted device's exchange. Cancelling the UI prevents a returned proof
/// from being used. Final approval also rechecks the current request atomically.
Future<VerifiedDeviceApproval> verifyPairingCode(
  DeviceVerificationRequest request,
  String code,
  PairingCodeMailbox mailbox, {
  required bool Function() isCurrent,
  Duration timeout = const Duration(seconds: 60),
}) async {
  void check() {
    if (!isCurrent()) throw StateError('Pairing session ended');
    request.requireValid(DateTime.now());
  }

  check();
  final initial = await mailbox.read();
  check();
  final rawOffer = initial?['offer'];
  if (rawOffer is! Map<String, dynamic> || initial!.containsKey('response')) {
    throw StateError('Show a fresh pairing code on the new device');
  }
  final client = await createPairingCodeClient(request, code, rawOffer);
  check();
  final id = rawOffer['id'];
  final result = Completer<Map<String, dynamic>>();
  // Subscribe before publishing; the other device can answer immediately.
  final subscription = mailbox.watch().listen(
    (value) {
      if (result.isCompleted) return;
      try {
        check();
        if (value?['offer'] is! Map || (value!['offer'] as Map)['id'] != id) {
          throw StateError('Pairing code did not match or expired');
        }
        final response = value['result'];
        if (response is Map<String, dynamic>) result.complete(response);
      } catch (_) {
        result.completeError(
          StateError('Pairing code did not match or expired'),
        );
      }
    },
    onError: (Object _) {
      if (!result.isCompleted) {
        result.completeError(StateError('Pairing session ended'));
      }
    },
  );
  // Attach an error handler immediately, even if the publication is still pending.
  final pending = result.future.timeout(timeout);
  unawaited(pending.then<void>((_) {}, onError: (Object _) {}));
  final cancellation = Timer.periodic(const Duration(milliseconds: 250), (_) {
    if (!isCurrent() && !result.isCompleted) {
      result.completeError(StateError('Pairing session ended'));
    }
  });
  try {
    await mailbox.change((current) {
      check();
      if (current?['offer'] is! Map ||
          (current!['offer'] as Map)['id'] != id ||
          current.containsKey('response') ||
          current.containsKey('result')) {
        throw StateError('Pairing offer already used');
      }
      return {...current, 'response': client.response};
    });
    check();
    final message = await pending;
    check();
    final verified = await client.finish(message);
    check();
    return verified;
  } finally {
    cancellation.cancel();
    await subscription.cancel();
  }
}
