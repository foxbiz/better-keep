import 'sync_limits.dart';
import 'storage_usage.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'file_sync_adapter.dart';
import 'provider_http.dart';
import 'sync_provider_adapter.dart';

class DropboxSyncTransport
    implements SyncFileTransport, SyncFileCleanup, StorageUsageReader {
  DropboxSyncTransport({
    required this.httpClient,
    required this.accessToken,
    required String libraryId,
  }) : root = '/betterkeep-v1/$libraryId' {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(libraryId)) {
      throw ArgumentError('Invalid library');
    }
  }

  final ProviderHttp httpClient;
  final Future<String> Function() accessToken;
  final String root;

  @override
  Future<StorageUsage?> readStorageUsage() async {
    final response = await httpClient.send(
      'POST',
      Uri.https('api.dropboxapi.com', '/2/users/get_space_usage'),
      headers: {
        'Authorization': 'Bearer ${await accessToken()}',
        'Content-Type': 'application/json',
      },
      body: Uint8List.fromList(utf8.encode('null')),
    );
    if (response.statusCode != 200) ProviderHttp.fail(response);
    final data = jsonDecode(response.body);
    if (data is! Map || data['allocation'] is! Map) return null;
    final allocation = data['allocation'] as Map;
    if (allocation['.tag'] == 'individual') {
      return StorageUsage.fromUsed(data['used'], allocation['allocated']);
    }
    if (allocation['.tag'] != 'team') return null;
    final team = StorageUsage.fromUsed(
      allocation['used'],
      allocation['allocated'],
    );
    if (team == null) return null;
    final limitType = allocation['user_within_team_space_limit_type'];
    final limited =
        limitType == 'stop_sync' ||
        (limitType is Map && limitType['.tag'] == 'stop_sync');
    final memberLimit = StorageUsage.bytes(
      allocation['user_within_team_space_allocated'],
    );
    if (!limited || memberLimit == 0) return team;
    final member = StorageUsage.fromUsed(
      allocation['user_within_team_space_used_cached'],
      memberLimit,
    );
    if (member == null) return null;
    return StorageUsage(
      usedBytes: member.totalBytes <= team.totalBytes
          ? member.usedBytes
          : team.usedBytes,
      freeBytes: member.freeBytes < team.freeBytes
          ? member.freeBytes
          : team.freeBytes,
      totalBytes: member.totalBytes < team.totalBytes
          ? member.totalBytes
          : team.totalBytes,
    );
  }

  @override
  Future<void> clearLibrary() async {
    // Do not initialize/create folders: cleanup must work when storage is full.
    final result = await _call('delete_v2', {'path': root});
    if (result.statusCode != 200 && !_error(result, 'path_lookup/not_found')) {
      ProviderHttp.fail(result);
    }
  }

  bool _initialized = false;

  String _path(String name) {
    if (!RegExp(r'^(o-[0-9a-f]{64}|c-[0-9a-f]{64}\.json)$').hasMatch(name)) {
      throw const FormatException('Invalid sync file name');
    }
    return '$root/$name';
  }

  Future<http.Response> _call(
    String route,
    Map<String, Object?> args, {
    Uint8List? data,
  }) async {
    final content = data != null;
    return httpClient.send(
      'POST',
      Uri.https(
        content ? 'content.dropboxapi.com' : 'api.dropboxapi.com',
        '/2/files/$route',
      ),
      headers: {
        'Authorization': 'Bearer ${await accessToken()}',
        'Content-Type': content
            ? 'application/octet-stream'
            : 'application/json',
        if (content) 'Dropbox-API-Arg': jsonEncode(args),
      },
      body: data ?? Uint8List.fromList(utf8.encode(jsonEncode(args))),
    );
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    for (final path in ['/betterkeep-v1', root]) {
      final result = await _call('create_folder_v2', {
        'path': path,
        'autorename': false,
      });
      if (result.statusCode != 200 && !_error(result, 'path/conflict/folder')) {
        ProviderHttp.fail(result);
      }
    }
    _initialized = true;
  }

  @override
  Future<SyncFilePage> list(String? cursor) async {
    await _initialize();
    final result = await _call(
      cursor == null ? 'list_folder' : 'list_folder/continue',
      cursor == null
          ? {'path': root, 'recursive': false, 'limit': 100}
          : {'cursor': cursor},
    );
    if (result.statusCode != 200) {
      if (_error(result, 'reset')) {
        throw const SyncProviderFailure(SyncProviderFailureKind.invalidCursor);
      }
      ProviderHttp.fail(result);
    }
    final json = _json(result);
    if (json['entries'] is! List ||
        json['cursor'] is! String ||
        json['has_more'] is! bool) {
      throw const FormatException('Invalid Dropbox listing');
    }
    final names = <String>[];
    for (final item in json['entries'] as List) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid Dropbox entry');
      }
      // Physical deletions are not application tombstones.
      if (item['.tag'] != 'file') continue;
      final name = item['name'];
      if (name is! String) throw const FormatException('Invalid Dropbox file');
      names.add(name);
    }
    return SyncFilePage(
      names: names,
      cursor: json['cursor'] as String,
      hasMore: json['has_more'] as bool,
    );
  }

  @override
  Future<Uint8List> read(String name) async {
    final response = await httpClient.send(
      'POST',
      Uri.https('content.dropboxapi.com', '/2/files/download'),
      maxResponseBytes: name.startsWith('c-')
          ? SyncLimits.commitBytes
          : SyncLimits.objectBytes,
      headers: {
        'Authorization': 'Bearer ${await accessToken()}',
        'Dropbox-API-Arg': jsonEncode({'path': _path(name)}),
      },
    );
    if (response.statusCode != 200) ProviderHttp.fail(response);
    return response.bodyBytes;
  }

  @override
  Future<bool> create(String name, Uint8List bytes) async {
    await _initialize();
    final commit = <String, Object?>{
      'path': _path(name),
      'mode': 'add',
      'autorename': false,
      'strict_conflict': true,
      'mute': true,
    };
    const chunkSize = 8 * 1024 * 1024;
    late final http.Response response;
    if (bytes.length <= chunkSize) {
      response = await _call('upload', commit, data: bytes);
    } else {
      final start = await _call('upload_session/start', {
        'close': false,
      }, data: Uint8List.sublistView(bytes, 0, chunkSize));
      if (start.statusCode != 200) ProviderHttp.fail(start);
      final session = _json(start)['session_id'];
      if (session is! String) {
        throw const FormatException('Invalid upload session');
      }
      var offset = chunkSize;
      while (bytes.length - offset > chunkSize) {
        final append = await _call('upload_session/append_v2', {
          'cursor': {'session_id': session, 'offset': offset},
          'close': false,
        }, data: Uint8List.sublistView(bytes, offset, offset + chunkSize));
        if (append.statusCode != 200) ProviderHttp.fail(append);
        offset += chunkSize;
      }
      response = await _call('upload_session/finish', {
        'cursor': {'session_id': session, 'offset': offset},
        'commit': commit,
      }, data: Uint8List.sublistView(bytes, offset));
    }
    if (response.statusCode == 200) return true;
    if (_error(response, 'path/conflict')) return false;
    if (_error(response, 'path/insufficient_space')) {
      throw const SyncProviderFailure(SyncProviderFailureKind.quotaExceeded);
    }
    ProviderHttp.fail(response);
  }

  static Map<String, dynamic> _json(http.Response response) {
    late final dynamic json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid provider response');
    }
    return json;
  }

  static bool _error(http.Response response, String prefix) {
    if (response.statusCode != 409) return false;
    final summary = _json(response)['error_summary'];
    return summary is String &&
        (summary == prefix || summary.startsWith('$prefix/'));
  }
}
