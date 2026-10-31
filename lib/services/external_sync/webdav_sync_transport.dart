import 'sync_limits.dart';
import 'dav_listing_reader.dart';
import 'storage_usage.dart';

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'file_sync_adapter.dart';
import 'provider_http.dart';
import 'sync_provider_adapter.dart';

/// WebDAV adapter. ETags detect changed immutable commit files; they are never
/// used as note timestamps. No Firebase proxy or arbitrary redirect is used.
class WebDavSyncTransport
    implements SyncFileTransport, SyncFileCleanup, StorageUsageReader {
  WebDavSyncTransport({
    required this.httpClient,
    required Uri server,
    required this.username,
    required this.appPassword,
    required this.libraryId,
  }) : server = normalizeServer(server) {
    if (username.isEmpty ||
        username.contains(':') ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(libraryId)) {
      throw ArgumentError('Invalid WebDAV connection');
    }
  }

  /// The exact DAV collection supplied by the user, never a discovered or
  /// redirected host. Credentials only travel to this HTTPS origin.
  static Uri normalizeServer(Uri value) {
    if (value.scheme != 'https' ||
        value.host.isEmpty ||
        value.port == 0 ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment ||
        value.pathSegments.any(
          (part) =>
              part == '.' ||
              part == '..' ||
              part.contains('/') ||
              part.contains('\\') ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(part),
        )) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    final segments = value.pathSegments.toList();
    while (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    return value.replace(pathSegments: segments);
  }

  final ProviderHttp httpClient;
  final Uri server;
  final String username;
  final Future<String> Function() appPassword;
  final String libraryId;
  bool _initialized = false;
  Map<String, String>? _listing;
  String? _continuation;
  Map<String, String>? _seen;
  List<String>? _remaining;
  int _offset = 0;
  String? _scanId;

  static const _dav = 'DAV:';

  @override
  Future<StorageUsage?> readStorageUsage() async {
    // Query the account root; no folder creation or library scan is necessary.
    final folder = _uri([]);
    final root = folder.replace(
      pathSegments: [
        ...folder.pathSegments.take(folder.pathSegments.length - 1),
        '',
      ],
    );
    final response = await _request(
      'PROPFIND',
      root,
      headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
      body: Uint8List.fromList(
        utf8.encode(
          '<d:propfind xmlns:d="DAV:"><d:prop><d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>',
        ),
      ),
    );
    if (response.statusCode != 207) ProviderHttp.fail(response);
    final entries = XmlDocument.parse(response.body).rootElement
        .findElements('response', namespaceUri: _dav)
        .toList();
    if (entries.length != 1) return null;
    int? available, used;
    for (final stat in entries.single.findElements(
      'propstat',
      namespaceUri: _dav,
    )) {
      final status =
          stat.getElement('status', namespaceUri: _dav)?.innerText ?? '';
      if (!RegExp(r'^HTTP/\S+ 200(?: |$)').hasMatch(status)) continue;
      final prop = stat.getElement('prop', namespaceUri: _dav);
      available ??= StorageUsage.bytes(
        prop
            ?.getElement('quota-available-bytes', namespaceUri: _dav)
            ?.innerText
            .trim(),
      );
      used ??= StorageUsage.bytes(
        prop
            ?.getElement('quota-used-bytes', namespaceUri: _dav)
            ?.innerText
            .trim(),
      );
    }
    if (available == null || used == null) return null;
    final total = StorageUsage.bytes(available + used);
    return total == null
        ? null
        : StorageUsage(freeBytes: available, totalBytes: total);
  }

  @override
  Future<void> clearLibrary() async {
    final response = await _request('DELETE', _uri([libraryId, '']));
    if (![200, 204, 404].contains(response.statusCode)) {
      ProviderHttp.fail(response);
    }
  }

  Uri _uri(List<String> suffix) => server.replace(
    pathSegments: [...server.pathSegments, 'BetterKeep', ...suffix],
  );

  Uri _file(String name) {
    if (!RegExp(r'^(o-[0-9a-f]{64}|c-[0-9a-f]{64}\.json)$').hasMatch(name)) {
      throw const FormatException('Invalid sync file name');
    }
    return _uri([libraryId, name]);
  }

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Uint8List? body,
    int maxResponseBytes = SyncLimits.metadataBytes,
  }) async => httpClient.send(
    method,
    uri,
    headers: {
      'Authorization':
          'Basic ${base64Encode(utf8.encode('$username:${await appPassword()}'))}',
      ...headers,
    },
    body: body,
    maxResponseBytes: maxResponseBytes,
  );

  Future<void> _initialize() async {
    if (_initialized) return;
    for (final uri in [
      _uri(['']),
      _uri([libraryId, '']),
    ]) {
      final response = await _request('MKCOL', uri);
      if (response.statusCode != 201 && response.statusCode != 405) {
        ProviderHttp.fail(response);
      }
    }
    _initialized = true;
  }

  /// Run before enabling a new connection. Some WebDAV servers silently ignore
  /// conditional PUT; such a server cannot preserve immutable sync objects.
  Future<void> probeImmutableWrites({bool verifyMetadata = false}) async {
    await _initialize();
    final random = Random.secure();
    final suffix = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final uri = _uri([libraryId, '.probe-$suffix']);
    final original = Uint8List.fromList(
      utf8.encode('betterkeep-probe-$suffix'),
    );
    final created = await _request(
      'PUT',
      uri,
      headers: {'If-None-Match': '*'},
      body: original,
    );
    if (created.statusCode != 201) {
      if (created.statusCode >= 400) ProviderHttp.fail(created);
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    var canaryDeleted = false;
    try {
      final conflict = await _request(
        'PUT',
        uri,
        headers: {'If-None-Match': '*'},
        body: Uint8List.fromList([0]),
      );
      if (conflict.statusCode != 412) {
        throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
      }
      final read = await _request('GET', uri);
      if (read.statusCode != 200 ||
          base64Encode(read.bodyBytes) != base64Encode(original)) {
        throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
      }
      if (verifyMetadata) {
        // An empty collection cannot prove that file ETags are supported.
        // Check this canary before accepting a generic server's credentials.
        final metadata = await _request(
          'PROPFIND',
          uri,
          headers: {
            'Depth': '0',
            'Content-Type': 'application/xml; charset=utf-8',
          },
          body: Uint8List.fromList(
            utf8.encode(
              '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>',
            ),
          ),
        );
        if (metadata.statusCode != 207) ProviderHttp.fail(metadata);
        final entries = XmlDocument.parse(metadata.body).rootElement
            .findElements('response', namespaceUri: _dav)
            .toList();
        final valid =
            entries.length == 1 &&
            (entries.single
                    .getElement('href', namespaceUri: _dav)
                    ?.innerText
                    .isNotEmpty ??
                false) &&
            uri.resolve(
                  entries.single
                          .getElement('href', namespaceUri: _dav)
                          ?.innerText ??
                      '',
                ) ==
                uri &&
            entries.single
                .findElements('propstat', namespaceUri: _dav)
                .any(
                  (stat) =>
                      RegExp(r'^HTTP/\S+ 200(?: |$)').hasMatch(
                        stat
                                .getElement('status', namespaceUri: _dav)
                                ?.innerText ??
                            '',
                      ) &&
                      (stat
                              .getElement('prop', namespaceUri: _dav)
                              ?.getElement('getetag', namespaceUri: _dav)
                              ?.innerText
                              .isNotEmpty ??
                          false),
                );
        if (!valid) {
          throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
        }
        final deleted = await _request('DELETE', uri);
        if (![200, 204].contains(deleted.statusCode)) {
          ProviderHttp.fail(deleted);
        }
        canaryDeleted = true;
        await list(null);
      }
    } finally {
      // Only this random canary can be deleted, never a library object. Cleanup
      // failure does not invalidate an otherwise successful capability check.
      try {
        if (!canaryDeleted) await _request('DELETE', uri);
      } catch (_) {}
    }
  }

  @override
  Future<SyncFilePage> list(String? cursor) async {
    await _initialize();
    final continuing =
        _listing != null && cursor != null && cursor == _continuation;
    final seen = continuing ? _seen! : <String, String>{};
    if (cursor != null && !continuing) {
      try {
        final data = jsonDecode(cursor);
        if (data is! Map<String, dynamic> ||
            data['version'] != 1 ||
            data['library'] != libraryId ||
            data['seen'] is! Map) {
          throw const FormatException('Invalid cursor');
        }
        seen.addAll((data['seen'] as Map).cast<String, String>());
      } catch (_) {
        throw const SyncProviderFailure(SyncProviderFailureKind.invalidCursor);
      }
    }
    // Reuse this scan only for its exact continuation. The final cursor starts
    // a new scan next time, so concurrent insertions are picked up then.
    Map<String, String> current;
    if (continuing) {
      current = _listing!;
    } else {
      current = {};
      final reader = DavListingReader((xml) {
        final entries = _parseListing(xml);
        for (final entry in entries.entries) {
          if (current.containsKey(entry.key) &&
              current[entry.key] != entry.value) {
            throw const SyncProviderFailure(
              SyncProviderFailureKind.corruptData,
            );
          }
          current[entry.key] = entry.value;
        }
        if (current.length > 100000) {
          throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
        }
      });
      final response = await httpClient.send(
        'PROPFIND',
        _uri([libraryId, '']),
        headers: {
          'Depth': '1',
          'Content-Type': 'application/xml; charset=utf-8',
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$username:${await appPassword()}'))}',
        },
        maxResponseBytes: 64 * 1024 * 1024,
        sizeFailure: SyncProviderFailureKind.unsupported,
        onResponseChunk: reader.addBytes,
        body: Uint8List.fromList(
          utf8.encode(
            '''<?xml version="1.0"?>
      <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:resourcetype/></d:prop></d:propfind>''',
          ),
        ),
      );
      if (response.statusCode != 207) ProviderHttp.fail(response);
      reader.finish();
      _listing = current;
      _seen = seen;
      _offset = 0;
      final random = Random.secure();
      _scanId = base64UrlEncode(List.generate(16, (_) => random.nextInt(256)));
    }
    if (!continuing) {
      seen.removeWhere((name, _) => !current.containsKey(name));
      _remaining =
          current.keys.where((name) => seen[name] != current[name]).toList()
            ..sort();
    }
    final page = _remaining!.skip(_offset).take(100).toList();
    _offset += page.length;
    final hasMore = _offset < _remaining!.length;
    for (final name in page) {
      seen[name] = current[name]!;
    }
    // Intermediate cursors refer to this in-memory scan, avoiding a growing
    // map on every page. A restart rejects them as invalidCursor; the replica
    // engine safely re-lists and deduplicates already committed revisions.
    // Final checkpoints retain the durable v1 format for existing clients.
    final nextCursor = jsonEncode(
      hasMore
          ? {
              'version': 2,
              'library': libraryId,
              'scan': _scanId,
              'offset': _offset,
            }
          : {'version': 1, 'library': libraryId, 'seen': seen},
    );
    _continuation = hasMore ? nextCursor : null;
    if (!hasMore) {
      _listing = _seen = null;
      _remaining = null;
      _scanId = null;
    }
    return SyncFilePage(names: page, cursor: nextCursor, hasMore: hasMore);
  }

  Map<String, String> _parseListing(String body) {
    late final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } catch (_) {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    }
    if (doc.rootElement.name.local != 'multistatus' ||
        doc.rootElement.namespaceUri != _dav) {
      throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
    }
    final entries = <String, String>{};
    final folder = _uri([libraryId, '']);
    for (final entry in doc.rootElement.findElements(
      'response',
      namespaceUri: _dav,
    )) {
      final href = entry.getElement('href', namespaceUri: _dav)?.innerText;
      if (href == null) throw const FormatException('Missing DAV resource');
      final target = folder.resolve(href);
      if (target.origin != folder.origin ||
          target.hasQuery ||
          target.hasFragment ||
          target.userInfo.isNotEmpty) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      final segments = target.pathSegments;
      if (segments.isEmpty) continue;
      final name = segments.last;
      if (!RegExp(r'^c-[0-9a-f]{64}\.json$').hasMatch(name)) continue;
      if (target != _file(name)) {
        throw const SyncProviderFailure(SyncProviderFailureKind.corruptData);
      }
      String? etag;
      for (final propstat in entry.findElements(
        'propstat',
        namespaceUri: _dav,
      )) {
        final status =
            propstat.getElement('status', namespaceUri: _dav)?.innerText ?? '';
        if (!RegExp(r'^HTTP/\S+ 200(?: |$)').hasMatch(status)) continue;
        final props = propstat.getElement('prop', namespaceUri: _dav);
        if (props
                ?.getElement('resourcetype', namespaceUri: _dav)
                ?.getElement('collection', namespaceUri: _dav) !=
            null) {
          continue;
        }
        etag = props?.getElement('getetag', namespaceUri: _dav)?.innerText;
      }
      if (etag == null || etag.isEmpty) {
        throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
      }
      entries[name] = etag;
    }
    return entries;
  }

  @override
  Future<Uint8List> read(String name) async {
    final response = await _request(
      'GET',
      _file(name),
      maxResponseBytes: name.startsWith('c-')
          ? SyncLimits.commitBytes
          : SyncLimits.objectBytes,
    );
    if (response.statusCode != 200) ProviderHttp.fail(response);
    return response.bodyBytes;
  }

  @override
  Future<bool> create(String name, Uint8List bytes) async {
    await _initialize();
    final response = await _request(
      'PUT',
      _file(name),
      headers: {
        'If-None-Match': '*',
        'Content-Type': 'application/octet-stream',
      },
      body: bytes,
    );
    if (response.statusCode == 201) return true;
    if (response.statusCode == 412) return false;
    if (response.statusCode == 204) {
      throw const SyncProviderFailure(SyncProviderFailureKind.unsupported);
    }
    ProviderHttp.fail(response);
  }
}
