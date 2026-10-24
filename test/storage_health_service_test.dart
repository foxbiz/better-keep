import 'package:better_keep/services/storage_health_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native low-space warning has hysteresis; unknown is not zero',
    () async {
      StorageReading reading = (availableBytes: null, usageRatio: null);
      final health = StorageHealthService(probe: () async => reading);
      addTearDown(health.dispose);
      await health.check();
      expect(health.isLow, false);
      reading = (availableBytes: 99 * 1024 * 1024, usageRatio: null);
      await health.check();
      expect(health.isLow, true);
      reading = (availableBytes: 120 * 1024 * 1024, usageRatio: null);
      await health.check();
      expect(health.isLow, true);
      reading = (availableBytes: 151 * 1024 * 1024, usageRatio: null);
      await health.check();
      expect(health.isLow, false);
    },
  );

  test(
    'browser estimates cannot override an actual full-storage error',
    () async {
      var ratio = .91;
      final health = StorageHealthService(
        probe: () async => (availableBytes: null, usageRatio: ratio),
      );
      addTearDown(health.dispose);
      await health.check();
      expect(health.isLow, true);
      ratio = .87;
      await health.check();
      expect(health.isLow, true);
      ratio = .2;
      await health.check();
      expect(health.isLow, false);
      health.reportError(StateError('QuotaExceededError'));
      await health.check();
      expect(health.isLow, true);
      health.reportWriteSuccess();
      await pumpEventQueue();
      expect(health.isLow, false);
    },
  );

  test(
    'unavailable probes and unrelated errors do not claim low storage',
    () async {
      final health = StorageHealthService(
        probe: () async => throw StateError('unavailable'),
      );
      addTearDown(health.dispose);
      await health.check();
      health.reportError(StateError('permission denied'));
      expect(health.isLow, false);
      health.reportError(StateError('database or disk is full'));
      expect(health.isLow, true);
      await health.check();
      expect(health.isLow, true);
    },
  );
}
