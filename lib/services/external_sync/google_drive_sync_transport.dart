import 'sync_limits.dart';
import 'storage_usage.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'file_sync_adapter.dart';
import 'provider_http.dart';
import 'sync_provider_adapter.dart';

/// Flat, app-private storage avoids folder creation races. Drive allows duplicate
/// names: all matching immutable copies are returned for protocol validation.
class GoogleDriveSyncTransport
    implements
        SyncFileTransport,
        SyncFileCopies,
        SyncFileCleanup,
        StorageUsageReader {
  GoogleDriveSyncTransport({
    required this.httpClient,
    required this.accessToken,
    required this.libraryId,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(libraryId)) {
      throw ArgumentError('Invalid sync library');
    }
  }

  final ProviderHttp httpClient;
  final Future<String> Function() accessToken;
  final String libraryId;

  static const _fileFields = 'id,name,appProperties,trashed';
  String get _query =>
      "'appDataFolder' in parents and trashed = false and appProperties has { key='library' and value='$libraryId' }";

  @override
  Future<StorageUsage?> readStorageUsage() async {
    final data = await _get('about', {'fields': 'storageQuota(limit,usage)'});
    final quota = data['storageQuota'];
    return quota is Map
        ? StorageUsage.fromUsed(quota['usage'], quota['limit'])
        : null;
  }

  @override
  Future<void> clearLibrary() async {
    // Re-list after each batch: deleting while advancing a list cursor can skip
    // entries. The bound leaves a resumable clearing state on persistent writers.
    for (var batch = 0; batch < 10000; batch++) {
      final result = await _get('files', {
        'q': _query,
        'spaces': 'appDataFolder',
        'pageSize': '100',
        'fields': 'files($_fileFields),nextPageToken',
      });
      final files = _files(result['files']);
      if (files.isEmpty) {
        if (result['nextPageToken'] != null) {
          throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
        }
        return;
      }
      for (final file in files) {
        if (_logicalName(file) == null) {
          throw const FormatException('Foreign file in library cleanup');
        }
        final id = _string(file, 'id');
        final response = await _request(
          'DELETE',
          Uri.https(
            'www.googleapis.com',
            '/',
          ).replace(pathSegments: ['drive', 'v3', 'files', id]),
        );
        if (response.statusCode != 204 && response.statusCode != 404) {
          _fail(response);
        }
      }
    }
    throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
  }

  String _remoteName(String name) {
    if (!RegExp(r'^(o-[0-9a-f]{64}|c-[0-9a-f]{64}\.json)$').hasMatch(name)) {
      throw const FormatException('Invalid sync file name');
    }
    return 'bk1-$libraryId-$name';
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Uint8List? body,
    Map<String, String> headers = const {},
    int maxResponseBytes = SyncLimits.metadataBytes,
  }) async => httpClient.send(
    method,
    uri,
    headers: {'Authorization': 'Bearer ${await accessToken()}', ...headers},
    body: body,
    maxResponseBytes: maxResponseBytes,
  );

  Future<Map<String, dynamic>> _get(
    String route,
    Map<String, String> query, {
    bool cursorRequest = false,
  }) async {
    final result = await _request(
      'GET',
      Uri.https('www.googleapis.com', '/drive/v3/$route', query),
    );
    if (result.statusCode != 200) {
      if (cursorRequest &&
          (result.statusCode == 400 || result.statusCode == 410)) {
        throw const SyncProviderFailure(SyncProviderFailureKind.invalidCursor);
      }
      _fail(result);
    }
    return _json(result);
  }

  String _cursor(String phase, String token, {String? page}) => jsonEncode({
    'v': 1,
    'library': libraryId,
    'phase': phase,
    'token': token,
    'page': ?page,
  });

  @override
  Future<SyncFilePage> list(String? cursor) async {
    String phase = 'bootstrap';
    late String token;
    String? page;
    if (cursor == null) {
      // Capture the change boundary BEFORE enumerating existing files.
      final start = await _get('changes/startPageToken', {
        'fields': 'startPageToken',
      });
      token = _string(start, 'startPageToken');
    } else {
      try {
        final value = jsonDecode(cursor) as Map<String, dynamic>;
        if (value['v'] != 1 ||
            value['library'] != libraryId ||
            !['bootstrap', 'changes'].contains(value['phase'])) {
          throw const FormatException('Invalid cursor');
        }
        phase = value['phase'] as String;
        token = _string(value, 'token');
        page = value['page'] as String?;
      } catch (_) {
        throw const SyncProviderFailure(SyncProviderFailureKind.invalidCursor);
      }
    }
    if (phase == 'bootstrap') {
      final result = await _get('files', {
        'spaces': 'appDataFolder',
        'q': _query,
        'pageSize': '100',
        'fields': 'nextPageToken,files($_fileFields)',
        'pageToken': ?page,
      }, cursorRequest: page != null);
      final names = _files(result['files'])
          .map(_logicalName)
          .whereType<String>()
          .toList();
      final next = _optionalString(result, 'nextPageToken');
      return SyncFilePage(
        names: names,
        cursor: next == null
            ? _cursor('changes', token)
            : _cursor('bootstrap', token, page: next),
        hasMore: true,
      );
    }
    final result = await _get('changes', {
      'spaces': 'appDataFolder',
      'pageToken': token,
      'pageSize': '100',
      'fields':
          'nextPageToken,newStartPageToken,changes(removed,file($_fileFields))',
    }, cursorRequest: true);
    final names = <String>[];
    for (final change in _files(result['changes'])) {
      if (change['removed'] == true || change['file'] == null) continue;
      final file = change['file'];
      if (file is! Map<String, dynamic>) {
        throw const FormatException('Invalid Drive change');
      }
      final name = _logicalName(file);
      if (name != null) names.add(name);
    }
    final next = _optionalString(result, 'nextPageToken');
    return SyncFilePage(
      names: names,
      cursor: _cursor('changes', next ?? _string(result, 'newStartPageToken')),
      hasMore: next != null,
    );
  }

  String? _logicalName(Map<String, dynamic> file) {
    if (file['trashed'] == true) return null;
    final properties = file['appProperties'];
    if (properties is! Map ||
        properties['library'] != libraryId ||
        properties['protocol'] != '1') {
      return null;
    }
    final name = properties['logical'];
    if (name is! String) {
      throw const FormatException('Invalid Drive sync metadata');
    }
    if (file['name'] != _remoteName(name)) {
      throw const FormatException('Mismatched Drive sync name');
    }
    return name;
  }

  Future<List<String>> _ids(String name) async {
    final remote = _remoteName(name);
    final ids = <String>[];
    final pages = <String>{};
    String? page;
    do {
      final result = await _get('files', {
        'spaces': 'appDataFolder',
        'q': "$_query and name = '$remote'",
        'pageSize': '100',
        'fields': 'nextPageToken,files($_fileFields)',
        'pageToken': ?page,
      });
      for (final file in _files(result['files'])) {
        if (_logicalName(file) != name) {
          throw const FormatException('Unexpected Drive object');
        }
        ids.add(_string(file, 'id'));
      }
      page = _optionalString(result, 'nextPageToken');
      if (page != null && (page.isEmpty || !pages.add(page))) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      if (ids.length > 100 || (page != null && ids.length >= 100)) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
    } while (page != null);
    ids.sort();
    return ids;
  }

  @override
  Future<List<Uint8List>> readCopies(String name) async {
    final ids = await _ids(name);
    if (ids.isEmpty) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    }
    final copies = <Uint8List>[];
    var remaining = name.startsWith('c-')
        ? SyncLimits.commitBytes
        : SyncLimits.objectBytes;
    for (final id in ids) {
      final response = await _request(
        'GET',
        Uri.https('www.googleapis.com', '/').replace(
          pathSegments: ['drive', 'v3', 'files', id],
          queryParameters: {'alt': 'media'},
        ),
        maxResponseBytes: remaining,
      );
      if (response.statusCode != 200) _fail(response);
      remaining -= response.bodyBytes.length;
      copies.add(response.bodyBytes);
    }
    return copies;
  }

  @override
  Future<Uint8List> read(String name) async => (await readCopies(name)).first;

  @override
  Future<bool> create(String name, Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw ArgumentError('Encrypted sync objects cannot be empty');
    }
    if ((await _ids(name)).isNotEmpty) return false;
    final metadata = {
      'name': _remoteName(name),
      'parents': ['appDataFolder'],
      'appProperties': {'library': libraryId, 'protocol': '1', 'logical': name},
    };
    final start = await _request(
      'POST',
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
        'uploadType': 'resumable',
        'fields': 'id',
      }),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'X-Upload-Content-Type': 'application/octet-stream',
        'X-Upload-Content-Length': '${bytes.length}',
      },
      body: Uint8List.fromList(utf8.encode(jsonEncode(metadata))),
    );
    if (start.statusCode != 200) _fail(start);
    final location = start.headers['location'];
    final session = location == null ? null : Uri.tryParse(location);
    if (session == null ||
        session.scheme != 'https' ||
        session.host != 'www.googleapis.com' ||
        session.port != 443 ||
        session.userInfo.isNotEmpty ||
        session.hasFragment ||
        session.path != '/upload/drive/v3/files') {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    }
    const chunk = 8 * 1024 * 1024; // Multiple of Drive's required 256 KiB.
    var offset = 0;
    var stalled = 0;
    while (offset < bytes.length) {
      final end = offset + chunk < bytes.length ? offset + chunk : bytes.length;
      final result = await _request(
        'PUT',
        session,
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Range': 'bytes $offset-${end - 1}/${bytes.length}',
        },
        body: Uint8List.sublistView(bytes, offset, end),
      );
      if (end == bytes.length &&
          (result.statusCode == 200 || result.statusCode == 201)) {
        return true;
      }
      if (result.statusCode == 308) {
        final range = result.headers['range'];
        final match = range == null
            ? null
            : RegExp(r'^bytes=0-([0-9]+)$').firstMatch(range);
        if (range != null && match == null) {
          throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
        }
        final next = match == null ? 0 : int.parse(match.group(1)!) + 1;
        if (next > end || next >= bytes.length || next < offset) {
          throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
        }
        stalled = next == offset ? stalled + 1 : 0;
        if (stalled >= 3) {
          throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
        }
        offset = next;
        continue;
      }
      _fail(result);
    }
    throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
  }

  static List<Map<String, dynamic>> _files(Object? value) {
    if (value == null) return [];
    if (value is! List || value.any((item) => item is! Map<String, dynamic>)) {
      throw const FormatException('Invalid Drive listing');
    }
    return value.cast<Map<String, dynamic>>();
  }

  static String? _optionalString(Map<String, dynamic> value, String field) =>
      value[field] == null ? null : _string(value, field);

  static String _string(Map<String, dynamic> value, String field) {
    final result = value[field];
    if (result is! String || result.isEmpty) {
      throw const FormatException('Invalid Drive response');
    }
    return result;
  }

  static Map<String, dynamic> _json(http.Response response) {
    try {
      final result = jsonDecode(response.body);
      if (result is Map<String, dynamic>) return result;
    } on FormatException {
      /* Do not include response bodies in errors. */
    }
    throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
  }

  static Never _fail(http.Response response) {
    if (response.statusCode == 403) {
      final error = _json(response)['error'];
      final errors = error is Map ? error['errors'] : null;
      if (errors is List) {
        final reasons = errors.whereType<Map>().map((e) => e['reason']).toSet();
        if (reasons.contains('storageQuotaExceeded')) {
          throw const SyncProviderFailure(
            SyncProviderFailureKind.quotaExceeded,
          );
        }
        if (reasons.intersection({
          'rateLimitExceeded',
          'userRateLimitExceeded',
          'dailyLimitExceeded',
        }).isNotEmpty) {
          throw const SyncProviderFailure(SyncProviderFailureKind.rateLimited);
        }
      }
    }
    ProviderHttp.fail(response);
  }
}
