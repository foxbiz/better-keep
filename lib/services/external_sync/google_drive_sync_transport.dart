import 'sync_limits.dart';
import 'storage_usage.dart';
import 'sync_metadata_index.dart';

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show listEquals;

import 'file_sync_adapter.dart';
import 'provider_http.dart';
import 'sync_provider_adapter.dart';

/// Flat, app-private storage avoids folder creation races. Drive allows duplicate
/// names: all matching immutable copies are returned for protocol validation.
class GoogleDriveSyncTransport
    implements
        SyncFileTransport,
        SyncFileCopies,
        SmallSyncFileReader,
        SyncIndexFileTransport,
        SyncValidatedIndexFileTransport,
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
  String? _indexId;

  static const multipartUploadBytes = 1024 * 1024;
  static final _random = Random.secure();

  static const _fileFields = 'id,name,appProperties,trashed,version';
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
    // Cleanup can stop early; never reuse a pre-cleanup index id afterwards.
    _indexId = null;
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
        // Index continuations are outside the old clients' commit query.
        // Relist while deleting so every linked/orphaned cache page is removed.
        for (var indexBatch = 0; indexBatch < 10000; indexBatch++) {
          final ids = await _indexIds(name: null);
          if (ids.isEmpty) return;
          for (final id in ids) {
            final response = await _request('DELETE', _fileUri(id));
            if (response.statusCode != 204 && response.statusCode != 404) {
              _fail(response);
            }
          }
        }
        throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
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
    Exception? sizeException,
    Duration? requestTimeout,
  }) async => httpClient.send(
    method,
    uri,
    headers: {'Authorization': 'Bearer ${await accessToken()}', ...headers},
    body: body,
    maxResponseBytes: maxResponseBytes,
    sizeException: sizeException,
    requestTimeout: requestTimeout,
  );

  Future<Map<String, dynamic>> _get(
    String route,
    Map<String, String> query, {
    bool cursorRequest = false,
    Duration? requestTimeout,
  }) async {
    final result = await _request(
      'GET',
      Uri.https('www.googleapis.com', '/drive/v3/$route', query),
      requestTimeout: requestTimeout,
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
      final files = _files(result['files']);
      final names = files.map(_logicalName).whereType<String>().toList();
      final next = _optionalString(result, 'nextPageToken');
      return SyncFilePage(
        names: names,
        cursor: next == null
            ? _cursor('changes', token)
            : _cursor('bootstrap', token, page: next),
        hasMore: true,
        commitVersions: _versions(files),
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
    final changedFiles = <Map<String, dynamic>>[];
    for (final change in _files(result['changes'])) {
      if (change['removed'] == true || change['file'] == null) continue;
      final file = change['file'];
      if (file is! Map<String, dynamic>) {
        throw const FormatException('Invalid Drive change');
      }
      final name = _logicalName(file);
      if (name != null) {
        names.add(name);
        changedFiles.add(file);
      }
    }
    final next = _optionalString(result, 'nextPageToken');
    return SyncFilePage(
      names: names,
      cursor: _cursor('changes', next ?? _string(result, 'newStartPageToken')),
      hasMore: next != null,
      commitVersions: _versions(changedFiles),
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

  Map<String, List<String>> _versions(List<Map<String, dynamic>> files) {
    final result = <String, List<String>>{};
    final unknown = <String>{};
    for (final file in files) {
      final name = _logicalName(file);
      if (name == null) continue;
      final version = file['version'];
      if (version is! String || version.isEmpty) {
        unknown.add(name);
      } else {
        (result[name] ??= []).add(jsonEncode([_string(file, 'id'), version]));
      }
    }
    for (final name in unknown) {
      result.remove(name);
    }
    return result;
  }

  Uri _fileUri(String id, {bool media = false}) =>
      Uri.https('www.googleapis.com', '/').replace(
        pathSegments: ['drive', 'v3', 'files', id],
        queryParameters: media ? {'alt': 'media'} : null,
      );

  String _indexName(String name) => 'bk1-$libraryId-$name';

  Future<List<String>> _indexIds({
    String? name = SyncMetadataIndex.fileName,
  }) async {
    if (name != null) SyncMetadataIndex.validateFileName(name);
    final result = await _get('files', {
      'q':
          "'appDataFolder' in parents and trashed = false and appProperties has { key='indexLibrary' and value='$libraryId' }${name == null ? '' : " and name = '${_indexName(name)}'"}",
      'spaces': 'appDataFolder',
      'pageSize': '100',
      'fields': 'nextPageToken,files($_fileFields)',
    }, requestTimeout: SyncMetadataIndex.lookupTimeout);
    // Cache duplicates are harmless, but never enumerate an unbounded set.
    if (name != null && result['nextPageToken'] != null) {
      throw const FormatException('Too many index copies');
    }
    final ids = <String>[];
    for (final file in _files(result['files'])) {
      final remoteName = file['name'];
      final prefix = 'bk1-$libraryId-';
      if (remoteName is! String ||
          !remoteName.startsWith(prefix) ||
          !(name == null
              ? SyncMetadataIndex.isCleanupFileName(
                  remoteName.substring(prefix.length),
                )
              : SyncMetadataIndex.isFileName(
                  remoteName.substring(prefix.length),
                )) ||
          (name != null && remoteName != _indexName(name)) ||
          file['appProperties'] is! Map ||
          file['appProperties']['indexLibrary'] != libraryId) {
        throw const FormatException('Invalid index location');
      }
      ids.add(_string(file, 'id'));
    }
    if (ids.isEmpty && result['nextPageToken'] != null) {
      throw const FormatException('Incomplete index listing');
    }
    return ids..sort();
  }

  @override
  Future<Uint8List?> readIndex({String name = SyncMetadataIndex.fileName}) =>
      _readIndex(name);

  @override
  Future<Uint8List?> readValidatedIndex(
    String name,
    void Function(Uint8List bytes) validate,
  ) => _readIndex(name, validate: validate);

  Future<Uint8List?> _readIndex(
    String name, {
    void Function(Uint8List bytes)? validate,
  }) async {
    SyncMetadataIndex.validateFileName(name);
    final head = name == SyncMetadataIndex.fileName;
    final tried = <String>{};
    List<String>? ids;
    FormatException? invalid;
    // Cache acceleration must not spend unbounded time on duplicate files.
    // Try the pinned head first, then at most three total candidates serially.
    while (tried.length < 3) {
      var id = head && !tried.contains(_indexId) ? _indexId : null;
      if (id == null) {
        ids ??= await _indexIds(name: name);
        id = ids.where((candidate) => !tried.contains(candidate)).firstOrNull;
      }
      if (id == null) break;
      tried.add(id);
      final response = await _request(
        'GET',
        _fileUri(id, media: true),
        maxResponseBytes: SyncMetadataIndex.maxBytes,
        requestTimeout: SyncMetadataIndex.requestTimeout,
      );
      if (response.statusCode == 404) {
        if (head) _indexId = null;
        // A plain read retains its existing one-request missing-file contract.
        if (validate == null) return null;
        continue;
      }
      if (response.statusCode != 200) _fail(response);
      final bytes = response.bodyBytes;
      try {
        validate?.call(bytes);
      } on FormatException catch (error) {
        invalid = error;
        if (head) _indexId = null;
        continue;
      }
      if (head) _indexId = id;
      return bytes;
    }
    if (invalid != null) throw invalid;
    return null;
  }

  @override
  Future<void> writeIndex(
    Uint8List bytes, {
    String name = SyncMetadataIndex.fileName,
  }) async {
    SyncMetadataIndex.validateWrite(name, bytes);
    final head = name == SyncMetadataIndex.fileName;
    final id =
        (head ? _indexId : null) ?? (await _indexIds(name: name)).firstOrNull;
    if (id == null) {
      final created = await _upload(bytes, {
        'name': _indexName(name), 'parents': ['appDataFolder'],
        // Separate metadata keeps the cache out of older clients' immutable
        // file scans. It cannot resurrect notes absent from the real listing.
        'appProperties': {'indexLibrary': libraryId},
      }, requestTimeout: SyncMetadataIndex.requestTimeout);
      if (head) _indexId = created;
      return;
    }
    if (head) _indexId = id;
    final response = await _request(
      'PATCH',
      Uri.https('www.googleapis.com', '/').replace(
        pathSegments: ['upload', 'drive', 'v3', 'files', id],
        queryParameters: {'uploadType': 'media'},
      ),
      headers: {'Content-Type': 'application/json'},
      body: bytes,
      requestTimeout: SyncMetadataIndex.requestTimeout,
    );
    if (head && response.statusCode == 404) _indexId = null;
    if (response.statusCode != 200) _fail(response);
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
  Future<List<Uint8List>> readCopies(String name) => _readCopies(name);

  @override
  Future<Uint8List?> readSmall(String name) async {
    // Commit copies can use different nonces for identical revisions. Only
    // content-addressed objects can use byte equality on this prefetch path.
    if (!name.startsWith('o-')) return null;
    try {
      final copies = await _readCopies(name, small: true);
      if (copies.skip(1).any((copy) => !listEquals(copy, copies.first))) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      return copies.first;
    } on SmallSyncReadLimitExceeded {
      return null; // Large media keeps the bounded, serial download path.
    }
  }

  Future<List<Uint8List>> _readCopies(String name, {bool small = false}) async {
    final ids = await _ids(name);
    if (ids.isEmpty) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unavailable);
    }
    final copies = <Uint8List>[];
    var remaining = small
        ? SyncLimits.prefetchBytes
        : name.startsWith('c-')
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
        sizeException: small ? const SmallSyncReadLimitExceeded() : null,
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
    await _upload(bytes, metadata);
    return true;
  }

  Future<String> _upload(
    Uint8List bytes,
    Map<String, Object?> metadata, {
    Duration? requestTimeout,
  }) async {
    // Small encrypted notes and commits do not need a resumable session.
    // Keep larger media on the chunked path, including on mobile connections.
    if (bytes.length <= multipartUploadBytes) {
      final boundary = List.generate(
        24,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final body = BytesBuilder(copy: false)
        ..add(
          utf8.encode(
            '--$boundary\r\n'
            'Content-Type: application/json; charset=UTF-8\r\n\r\n'
            '${jsonEncode(metadata)}\r\n'
            '--$boundary\r\n'
            'Content-Type: application/octet-stream\r\n\r\n',
          ),
        )
        ..add(bytes)
        ..add(utf8.encode('\r\n--$boundary--\r\n'));
      final result = await _request(
        'POST',
        Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
          'uploadType': 'multipart',
          'fields': 'id',
        }),
        headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
        body: body.takeBytes(),
        requestTimeout: requestTimeout,
      );
      if (result.statusCode != 200 && result.statusCode != 201) _fail(result);
      return _string(_json(result), 'id');
    }
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
      requestTimeout: requestTimeout,
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
        requestTimeout: requestTimeout,
      );
      if (end == bytes.length &&
          (result.statusCode == 200 || result.statusCode == 201)) {
        return _string(_json(result), 'id');
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
