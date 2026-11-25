import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:better_keep/services/external_sync/storage_usage.dart';
import 'package:better_keep/services/external_sync/provider_http.dart';
import 'package:better_keep/services/external_sync/google_drive_sync_transport.dart';
import 'package:better_keep/services/external_sync/dropbox_sync_transport.dart';
import 'package:better_keep/services/external_sync/nextcloud_sync_transport.dart';

void main() {
  final library = 'a' * 64;
  test(
    'Drive uses all-services usage; absent limits are not zero capacity',
    () async {
      final quota = <String, dynamic>{
        'limit': '15000',
        'usage': '6000',
        'usageInDrive': '1000',
      };
      final client = MockClient((r) async {
        expect(r.method, 'GET');
        expect(r.url.path, '/drive/v3/about');
        expect(r.url.queryParameters['fields'], 'storageQuota(limit,usage)');
        return http.Response(jsonEncode({'storageQuota': quota}), 200);
      });
      addTearDown(client.close);
      final reader = GoogleDriveSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'test',
        libraryId: library,
      );
      final result = await reader.readStorageUsage();
      expect(result!.freeBytes, 9000);
      expect(result.usedBytes, 6000);
      expect(result.totalBytes, 15000);
      quota.remove('limit');
      expect(await reader.readStorageUsage(), isNull);
    },
  );
  test(
    'Dropbox accounts, shared team capacity and enforced member limits',
    () async {
      Map<String, dynamic> allocation = {
        '.tag': 'individual',
        'allocated': 1000,
      };
      final client = MockClient((r) async {
        expect(r.method, 'POST');
        expect(r.url.path, '/2/users/get_space_usage');
        return http.Response(
          jsonEncode({'used': 100, 'allocation': allocation}),
          200,
        );
      });
      addTearDown(client.close);
      final reader = DropboxSyncTransport(
        httpClient: ProviderHttp(client),
        accessToken: () async => 'test',
        libraryId: library,
      );
      expect((await reader.readStorageUsage())!.freeBytes, 900);
      allocation = {
        '.tag': 'team',
        'allocated': 1000,
        'used': 800,
        'user_within_team_space_allocated': 0,
      };
      expect((await reader.readStorageUsage())!.freeBytes, 200);
      allocation.addAll({
        'user_within_team_space_limit_type': {'.tag': 'stop_sync'},
        'user_within_team_space_allocated': 300,
        'user_within_team_space_used_cached': 250,
      });
      final member = (await reader.readStorageUsage())!;
      expect(member.freeBytes, 50);
      expect(member.usedBytes, 250);
      expect(member.totalBytes, 300);
      allocation['.tag'] = 'unknown';
      expect(await reader.readStorageUsage(), isNull);
    },
  );
  test('Nextcloud uses root quota with successful DAV properties only', () async {
    var available = '700', status = '200 OK';
    final client = MockClient((r) async {
      expect(r.method, 'PROPFIND');
      expect(r.url.path, '/nextcloud/remote.php/dav/files/dav-id/');
      expect(r.headers['depth'], '0');
      expect(r.body, contains('quota-available-bytes'));
      return http.Response(
        '''<d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop><d:quota-available-bytes>$available</d:quota-available-bytes><d:quota-used-bytes>300</d:quota-used-bytes></d:prop><d:status>HTTP/1.1 $status</d:status></d:propstat></d:response></d:multistatus>''',
        207,
      );
    });
    addTearDown(client.close);
    final reader = NextcloudSyncTransport(
      httpClient: ProviderHttp(client),
      server: Uri.parse('https://example.test/nextcloud'),
      username: 'login',
      davUserId: 'dav-id',
      appPassword: () async => 'test',
      libraryId: library,
    );
    final result = (await reader.readStorageUsage())!;
    expect(result.freeBytes, 700);
    expect(result.totalBytes, 1000);
    available = '-3';
    expect(await reader.readStorageUsage(), isNull);
    available = '700';
    status = '404 Not Found';
    expect(await reader.readStorageUsage(), isNull);
  });
  test(
    'over-capacity is zero free; malformed and unsafe amounts stay unknown',
    () {
      expect(StorageUsage.fromUsed(110, 100)!.freeBytes, 0);
      expect(StorageUsage.fromUsed(110, 100)!.usedBytes, 110);
      for (final value in [-1, 'unknown', 3.5, '9007199254740992', null]) {
        expect(StorageUsage.fromUsed(value, 100), isNull);
      }
      expect(StorageUsage.fromUsed(0, 0)!.totalBytes, 0);
    },
  );
}
