import 'package:better_keep/services/firebase_emulator_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const physicalDeviceHost = '192.168.1.25';

  String selectHost({
    bool isWeb = false,
    TargetPlatform platform = TargetPlatform.iOS,
    bool isAndroidEmulator = false,
    bool isAppleSimulator = false,
    String host = physicalDeviceHost,
  }) {
    return selectFirebaseEmulatorHost(
      isWeb: isWeb,
      platform: platform,
      isAndroidEmulator: isAndroidEmulator,
      isAppleSimulator: isAppleSimulator,
      physicalDeviceHost: host,
    );
  }

  group('selectFirebaseEmulatorHost', () {
    test('uses explicit IPv4 loopback for browsers', () {
      expect(
        selectHost(isWeb: true, platform: TargetPlatform.linux),
        firebaseEmulatorLoopbackHost,
      );
    });

    test('uses the Android host alias for an Android emulator', () {
      expect(
        selectHost(platform: TargetPlatform.android, isAndroidEmulator: true),
        androidEmulatorHost,
      );
    });

    test('uses IPv4 loopback for an Apple simulator', () {
      expect(
        selectHost(platform: TargetPlatform.iOS, isAppleSimulator: true),
        firebaseEmulatorLoopbackHost,
      );
    });

    test('uses loopback for a Windows client without an explicit host', () {
      expect(
        selectHost(platform: TargetPlatform.windows, host: ''),
        firebaseEmulatorLoopbackHost,
      );
    });

    test('uses an explicit remote host for a Windows client', () {
      expect(selectHost(platform: TargetPlatform.windows), physicalDeviceHost);
    });

    test('uses the configured LAN address for a physical device', () {
      expect(selectHost(), physicalDeviceHost);
    });
  });

  group('normalizePhysicalFirebaseEmulatorHost', () {
    test('normalizes valid IPv4 addresses and hostnames', () {
      expect(
        normalizePhysicalFirebaseEmulatorHost(' 192.168.1.25 '),
        '192.168.1.25',
      );
      expect(
        normalizePhysicalFirebaseEmulatorHost('DEV-MAC.local'),
        'dev-mac.local',
      );
    });

    test('rejects addresses that cannot route from a physical device', () {
      for (final host in [
        '',
        'localhost',
        '127.0.0.1',
        '0.0.0.0',
        androidEmulatorHost,
        'http://192.168.1.25',
        '192.168.1.25:9099',
        '999.1.1.1',
      ]) {
        expect(
          () => normalizePhysicalFirebaseEmulatorHost(host),
          throwsFormatException,
          reason: host,
        );
      }
    });
  });

  group('FirebaseEmulatorEndpoints', () {
    const endpoints = FirebaseEmulatorEndpoints('192.168.1.25');

    test('builds Functions and Hosting URLs from the resolved host', () {
      expect(
        endpoints.functionsBaseUrl(
          projectId: 'better-keep-notes',
          region: 'us-central1',
        ),
        'http://192.168.1.25:5001/better-keep-notes/us-central1',
      );
      expect(endpoints.hostingBaseUrl, 'http://192.168.1.25:5002');
    });

    test('lists every app-facing emulator service', () {
      expect(endpoints.requiredServices, {
        'Authentication': 9099,
        'Cloud Firestore': 8080,
        'Cloud Functions': 5001,
        'Cloud Storage': 9199,
        'Firebase Hosting': 5002,
      });
    });
  });

  test('unavailable exception identifies the host and failed services', () {
    final error = FirebaseEmulatorUnavailableException(
      host: '192.168.1.25',
      failures: {'Authentication (9099)': const SocketExceptionForTest()},
    );

    expect(error.toString(), contains('192.168.1.25'));
    expect(error.toString(), contains('Authentication (9099)'));
    expect(error.toString(), contains('firewall'));
  });
}

class SocketExceptionForTest {
  const SocketExceptionForTest();

  @override
  String toString() => 'connection refused';
}
