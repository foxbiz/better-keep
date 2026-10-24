import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_scoped_preferences.dart';
import 'storage_probe_native.dart'
    if (dart.library.js_interop) 'storage_probe_web.dart'
    as platform;

typedef StorageReading = ({int? availableBytes, double? usageRatio});

/// Best-effort warning only: storage pressure is never evidence of data loss.
class StorageHealthService extends ChangeNotifier {
  StorageHealthService({Future<StorageReading> Function()? probe})
    : _probe = probe ?? platform.probeStorage;

  static final instance = StorageHealthService();
  final Future<StorageReading> Function() _probe;
  SharedPreferences? _preferences;
  Timer? _timer;
  bool _checking = false;
  bool _low = false;
  bool _writeFailed = false;
  bool _disposed = false;
  bool get isLow => _low;

  // Outside account preferences, including the emulator prefix, so logout
  // preserves the explanation without retaining account information.
  static String deviceKey(String name, SharedPreferences preferences) =>
      'storage_recovery.${FirebaseScopedPreferences.scopeForPreferences(preferences).name}.$name';

  void start(SharedPreferences preferences) {
    _preferences = preferences;
    setForeground(true);
  }

  void setForeground(bool foreground) {
    _timer?.cancel();
    _timer = null;
    if (!foreground) return;
    unawaited(check());
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(check()),
    );
  }

  Future<void> check() async {
    if (_checking) return;
    _checking = true;
    try {
      final reading = await _probe().timeout(const Duration(seconds: 3));
      final bytes = reading.availableBytes;
      final ratio = reading.usageRatio;
      if (bytes != null && bytes >= 0) {
        _setLow(bytes < (_low ? 150 : 100) * 1024 * 1024);
      } else if (ratio != null && ratio.isFinite && ratio >= 0) {
        _setLow(ratio >= (_low ? 0.85 : 0.90));
      }
    } catch (_) {
      // Unknown is not zero free space. Do not log to a possibly full disk.
    } finally {
      _checking = false;
    }
  }

  void reportError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('quotaexceedederror') ||
        message.contains('sqlite_full') ||
        message.contains('database or disk is full') ||
        message.contains('no space left on device') ||
        message.contains('not enough space on the disk') ||
        message.contains('disk full')) {
      _writeFailed = true;
      _setLow(true);
    }
  }

  void reportWriteSuccess() {
    if (!_writeFailed) return;
    _writeFailed = false;
    unawaited(check());
  }

  void _setLow(bool value) {
    if (_disposed || (!value && _writeFailed) || _low == value) return;
    _low = value;
    // Notifiers may be observed by widgets while a synchronous error is logged.
    scheduleMicrotask(() {
      if (!_disposed) notifyListeners();
    });
    final preferences = _preferences;
    if (value && preferences != null) {
      unawaited(_rememberPressure(preferences));
    }
  }

  Future<void> _rememberPressure(SharedPreferences preferences) async {
    try {
      await preferences.setInt(
        deviceKey('pressure_at', preferences),
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // The warning must still work if storage cannot retain its reason.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
