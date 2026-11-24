import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/sync_metadata_index.dart';
import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Shared synthetic Dropbox HTTP boundary; sync, encryption and storage remain real.
class DropboxHttpFixture {
  DropboxHttpFixture({this.accessToken = 'synthetic', this.pageSize = 100});

  final String accessToken;
  final files = <String, Uint8List>{};
  final sessions = <String, Uint8List>{};
  int sessionSequence = 0;
  int requests = 0, uploads = 0, downloads = 0, indexWrites = 0;
  int concurrentDownloads = 0, maxConcurrentDownloads = 0;
  Duration delay = Duration.zero;
  int pageSize;
  Future<void> Function(int offset)? beforeContinue;
  int? failDownloadAt, loseUploadAckAt;
  bool offline = false;
  Future<http.Response> handle(http.Request request) async {
    requests++;
    if (offline) return http.Response('unavailable', 503);
    final downloading = request.url.path == '/2/files/download';
    final downloadNumber = downloading ? downloads + 1 : null;
    if (downloading) {
      downloads++;
      concurrentDownloads++;
      if (concurrentDownloads > maxConcurrentDownloads) {
        maxConcurrentDownloads = concurrentDownloads;
      }
    }
    if (delay != Duration.zero) await Future<void>.delayed(delay);
    if (downloading) {
      concurrentDownloads--;
      if (downloadNumber == failDownloadAt) {
        return http.Response('unavailable', 503);
      }
    }
    expectSync(request.headers['authorization'], 'Bearer $accessToken');
    expectSync(request.method, 'POST');
    final args =
        jsonDecode(request.headers['dropbox-api-arg'] ?? request.body) as Map;
    switch (request.url.path) {
      case '/2/files/create_folder_v2':
        return http.Response('{}', 200);
      case '/2/files/list_folder':
      case '/2/files/list_folder/continue':
        final offset = int.parse(args['cursor'] as String? ?? '0');
        if (request.url.path.endsWith('/continue')) {
          await beforeContinue?.call(offset);
        }
        final end = (offset + pageSize).clamp(0, files.length);
        return http.Response(
          jsonEncode({
            'entries': files.keys
                .skip(offset)
                .take(pageSize)
                .map(
                  (path) => {
                    '.tag': 'file',
                    'name': p.basename(path),
                    'id': path,
                    'rev': sha256.convert(files[path]!).toString(),
                  },
                )
                .toList(),
            'cursor': '$end',
            'has_more': end < files.length,
          }),
          200,
        );
      case '/2/files/upload_session/start':
        expectSync(args['close'], isTrue);
        final id = '${++sessionSequence}';
        sessions[id] = Uint8List.fromList(request.bodyBytes);
        return http.Response(jsonEncode({'session_id': id}), 200);
      case '/2/files/upload_session/finish_batch_v2':
        final results = <Map<String, Object?>>[];
        for (final entry in args['entries'] as List) {
          final cursor = entry['cursor'] as Map;
          final commit = entry['commit'] as Map;
          final bytes = sessions.remove(cursor['session_id'])!;
          expectSync(cursor['offset'], bytes.length);
          expectSync(commit['mode'], 'add');
          expectSync(commit['autorename'], isFalse);
          expectSync(commit['strict_conflict'], isTrue);
          final path = commit['path'] as String;
          uploads++;
          if (files.containsKey(path)) {
            results.add({
              '.tag': 'failure',
              'failure': {
                '.tag': 'path',
                'path': {
                  '.tag': 'conflict',
                  'conflict': {'.tag': 'file'},
                },
              },
            });
          } else {
            files[path] = bytes;
            results.add({'.tag': 'success', 'name': p.basename(path)});
          }
          if (uploads == loseUploadAckAt) return http.Response('lost ack', 503);
        }
        return http.Response(jsonEncode({'entries': results}), 200);
      case '/2/files/upload':
        if (SyncMetadataIndex.isFileName(p.basename(args['path'] as String))) {
          expectSync(args['mode'], 'overwrite');
          expectSync(args['autorename'], false);
          expectSync(args['mute'], true);
          indexWrites++;
          files[args['path'] as String] = Uint8List.fromList(request.bodyBytes);
          return http.Response('{}', 200);
        }
        expectSync(args['mode'], 'add');
        expectSync(args['strict_conflict'], isTrue);
        uploads++;
        final path = args['path'] as String;
        if (files.containsKey(path)) {
          return http.Response('{"error_summary":"path/conflict/file"}', 409);
        }
        files[path] = Uint8List.fromList(request.bodyBytes);
        if (uploads == loseUploadAckAt) return http.Response('lost ack', 503);
        return http.Response('{}', 200);
      case '/2/files/download':
        final bytes = files[args['path']];
        return bytes == null
            ? http.Response('{"error_summary":"path/not_found/"}', 409)
            : http.Response.bytes(bytes, 200);
      default:
        throw StateError('Unexpected Dropbox route ${request.url.path}');
    }
  }
}
