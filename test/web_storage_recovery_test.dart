@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:better_keep/services/storage_health_service.dart';
import 'package:better_keep/services/remote_sync_cache_service.dart';
import 'package:better_keep/services/scoped_file_system.dart';
import 'package:better_keep/services/storage_probe_web.dart';
import 'package:better_keep/services/web_file_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('masked Chrome quota cannot clear an actual storage failure', () async {
    final storage = web.window.navigator.storage;
    final original = storage.getProperty<JSFunction>('estimate'.toJS);
    addTearDown(() => storage.setProperty('estimate'.toJS, original));
    storage.setProperty(
      'estimate'.toJS,
      (() => Future.value(
        web.StorageEstimate(usage: 746365, quota: 10738164605),
      ).toJS).toJS,
    );
    expect((await probeStorage()).usageRatio, null);
    final health = StorageHealthService(probe: probeStorage);
    addTearDown(health.dispose);
    health.reportError(StateError('QuotaExceededError'));
    health.reportWriteSuccess();
    await pumpEventQueue();
    expect(health.isLow, true);

    storage.setProperty(
      'estimate'.toJS,
      (() => Future.value(
        web.StorageEstimate(usage: 746365, quota: 800000),
      ).toJS).toJS,
    );
    expect((await probeStorage()).usageRatio, greaterThan(0.9));
  });

  test(
    'browser cache reset tolerates absence and actually removes old metadata',
    () async {
      final fs = ScopedFileSystem(
        await WebFileSystem.instance(),
        directoryName:
            'storage-fixture-${DateTime.now().microsecondsSinceEpoch}',
      );
      final cache = RemoteSyncCacheService.forTesting(() async => fs);
      final metadataPath =
          '${await fs.cacheDir}/remote_sync_cache/metadata.json';
      expect(await fs.exists(metadataPath), false);
      await cache.clear(strict: true);
      await cache.startNewSync(null);
      expect(await fs.exists(metadataPath), true);
      await cache.clear(strict: true);
      expect(await fs.exists(metadataPath), false);
      final restarted = RemoteSyncCacheService.forTesting(() async => fs);
      await restarted.init();
      expect(restarted.metadata, null);
    },
  );

  test('browser storage probe does not claim device free bytes', () async {
    final reading = await probeStorage();
    expect(reading.availableBytes, null);
    expect(reading.usageRatio, anyOf(isNull, greaterThanOrEqualTo(0)));
  });
}
