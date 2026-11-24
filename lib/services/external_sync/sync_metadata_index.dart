import 'dart:convert';
import 'dart:typed_data';

import 'sync_cipher.dart';
import 'sync_json.dart';
import 'sync_revision.dart';

/// Authenticated plaintext metadata, never the remote inventory. Each bounded
/// page links to the next; the chain has no fixed total entry/page limit.
class SyncMetadataIndex {
  SyncMetadataIndex(this.cipher, this.scope);

  static const fileName = 'metadata-index-v3.json';
  static const maxBytes = 8 * 1024 * 1024;
  static const requestTimeout = Duration(seconds: 60);
  static const writeTimeout = Duration(seconds: 5);
  static const lookupTimeout = Duration(seconds: 10);
  // These limits apply to one file, not the library. Leave room for the envelope
  // and worst-case escaping when its JSON payload is encoded as a string.
  static const maxPageEntries = 4096;
  static const _payloadBudget = (maxBytes - 4096) ~/ 2;
  static final _pagePattern = RegExp(
    r'^metadata-index-v3-page-[1-9][0-9]*\.json$',
  );
  static final _commitPattern = RegExp(r'^c-[0-9a-f]{64}\.json$');

  final SyncCipher cipher;
  final String scope;
  final _entries = <String, _Entry>{};
  bool dirty = false;
  int _mutation = 0;
  _Upload? _upload;
  final _knownPages = <String, _Page>{};

  static bool isFileName(String name) =>
      name == fileName || _pagePattern.hasMatch(name);

  static void validateFileName(String name) {
    if (!isFileName(name)) {
      throw const FormatException('Invalid index file name');
    }
  }

  static void validateWrite(String name, Uint8List bytes) {
    validateFileName(name);
    if (bytes.length > maxBytes) throw const FormatException('Index too large');
  }

  static String pageName(int position) {
    if (position < 0) throw ArgumentError.value(position, 'position');
    return position == 0 ? fileName : 'metadata-index-v3-page-$position.json';
  }

  /// Legacy caches are removable only during explicit whole-library cleanup.
  static bool isCleanupFileName(String name) =>
      isFileName(name) ||
      name == 'metadata-index-v1.json' ||
      name == 'metadata-index-v2.json' ||
      RegExp(r'^metadata-index-v2-[0-9a-f]{64}\.json$').hasMatch(name);

  Set<String> get names => _entries.keys.toSet();

  /// Retains authenticated metadata for version-checked lookups, but forgets
  /// remote page acknowledgements so a validated full scan can rebuild them.
  void invalidateRemotePages() {
    _knownPages.clear();
    _upload = null;
    _mutation++;
    dirty = true;
  }

  SyncRevision? lookup(String name, List<String>? versions) {
    final entry = _entries[name];
    if (entry == null || versions == null || versions.isEmpty) return null;
    return versions.toSet().length == entry.versions.length &&
            versions.every(entry.versions.contains)
        ? entry.revision
        : null;
  }

  void forget(String name) {
    if (_entries.remove(name) == null) return;
    _mutation++;
    dirty = true;
  }

  void remember(String name, List<String>? versions, SyncRevision revision) {
    if (!_commitPattern.hasMatch(name) || !_validVersions(versions)) return;
    final tokens = versions!.toSet().toList()..sort();
    final next = _Entry(tokens, revision);
    if (_entries[name]?.encoded == next.encoded) return;
    if (_entryBytes(name, next) > _payloadBudget) return;
    // Updating an entry preserves its position, so unchanged page boundaries do
    // not shift just because a note was edited.
    _entries[name] = next;
    _mutation++;
    dirty = true;
  }

  static bool _validVersions(List<dynamic>? versions) =>
      versions != null &&
      versions.isNotEmpty &&
      versions.length <= 100 &&
      versions.every((v) => v is String && v.isNotEmpty && v.length <= 1024);

  static int _entryBytes(String name, _Entry entry) =>
      name.length + 4 + entry.bytes; // ASCII name, quotes, colon and comma.

  /// Writes only changed pages, tail first. Stable page names prevent a tail
  /// edit from renaming every earlier page or retaining a new chain per edit.
  /// Pages authenticate independently: concurrent writers can leave stale/mixed
  /// cache pages, so inventory/version checks and commit fallback remain required.
  /// The callback must enforce the caller's per-pass budget.
  Future<void> upload(
    Future<void> Function(String name, Uint8List bytes) write,
  ) async {
    if (!dirty && _upload == null) return;
    final pending = _upload ??= _snapshot();
    while (pending.position >= 0) {
      final name = pageName(pending.position);
      final entries = pending.pages[pending.position];
      final next = pending.position + 1 < pending.pages.length
          ? pageName(pending.position + 1)
          : null;
      final known = _knownPages[name];
      // Entries are immutable and remember() retains equal entries. Compare
      // identities/cached content before serializing an unchanged page. Content
      // equality also avoids a write if changes reverted before maintenance.
      if (known == null ||
          known.next != next ||
          known.entries.length != entries.length ||
          !entries.entries.every(
            (e) =>
                identical(known.entries[e.key], e.value) ||
                known.entries[e.key]?.encoded == e.value.encoded,
          )) {
        final bytes = pending.bytes ??= _encodePage(name, entries, next);
        await write(name, bytes);
        _knownPages[name] = (entries: entries, next: next);
      }
      pending.bytes = null;
      pending.position--;
    }
    final activePages = {
      for (var i = 0; i < pending.pages.length; i++) pageName(i),
    };
    _knownPages.removeWhere((name, _) => !activePages.contains(name));
    _upload = null;
    // Changes arriving between maintenance passes require a subsequent snapshot.
    dirty = _mutation != pending.mutation;
  }

  _Upload _snapshot() {
    final pages = <Map<String, _Entry>>[];
    var page = <String, _Entry>{};
    var size = 0;
    for (final entry in _entries.entries) {
      final cost = _entryBytes(entry.key, entry.value);
      if (page.isNotEmpty &&
          (page.length >= maxPageEntries || size + cost > _payloadBudget)) {
        pages.add(page);
        page = {};
        size = 0;
      }
      page[entry.key] = entry.value;
      size += cost;
    }
    if (page.isNotEmpty || pages.isEmpty) pages.add(page);
    return _Upload(pages, _mutation);
  }

  Uint8List _encodePage(
    String name,
    Map<String, _Entry> entries,
    String? next,
  ) {
    final payload = canonicalSyncJson({
      'version': 3,
      'page': name,
      'library': cipher.libraryId,
      'scope': scope,
      'next': next,
      'entries': {for (final e in entries.entries) e.key: e.value.toJson()},
    });
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode({'payload': payload, 'mac': _mac(payload)})),
    );
    if (bytes.length > maxBytes) {
      throw const FormatException('Index page too large');
    }
    return bytes;
  }

  /// Loads a whole linked snapshot without exposing a partial cache on failure.
  /// Buffers one encoded page at a time; retained decoded metadata scales with
  /// the library. Missing/corrupt links fall back to the original commit scan.
  Future<bool> loadChain(
    Future<Uint8List?> Function(String name) read, {
    Future<Uint8List?> Function(String name, void Function(Uint8List) validate)?
    readValidated,
  }) async {
    final parsed = <String, _Entry>{};
    final visited = <String>{};
    final pages = <String, _Page>{};
    String? name = fileName;
    while (name != null) {
      if (!visited.add(name)) throw const FormatException('Index chain cycle');
      _Page? validatedPage;
      Uint8List? validatedBytes;
      void validate(Uint8List bytes) {
        validatedPage = _decodePage(bytes, name!);
        validatedBytes = bytes;
      }

      final bytes = readValidated == null
          ? await read(name)
          : await readValidated(name, validate);
      if (bytes == null) {
        if (name == fileName) return false;
        throw const FormatException('Missing index page');
      }
      final page = identical(bytes, validatedBytes)
          ? validatedPage!
          : _decodePage(bytes, name);
      pages[name] = page;
      for (final entry in page.entries.entries) {
        if (parsed.containsKey(entry.key)) {
          throw const FormatException('Duplicate index entry');
        }
        parsed[entry.key] = entry.value;
      }
      name = page.next;
    }
    _replace(parsed, pages);
    return true;
  }

  /// Single-page inspection helper; production readers must use loadChain().
  void load(Uint8List bytes) {
    final page = _decodePage(bytes, fileName);
    if (page.next != null) {
      throw const FormatException('Incomplete index chain');
    }
    _replace(page.entries, {fileName: page});
  }

  void _replace(Map<String, _Entry> entries, Map<String, _Page> pages) {
    _knownPages
      ..clear()
      ..addAll(pages);
    _entries
      ..clear()
      ..addAll(entries);
    _mutation++;
    _upload = null;
    dirty = false;
  }

  _Page _decodePage(Uint8List bytes, String name) {
    if (bytes.length > maxBytes) throw const FormatException('Index too large');
    final envelope = jsonDecode(utf8.decode(bytes));
    if (envelope is! Map ||
        envelope['payload'] is! String ||
        envelope['mac'] is! String) {
      throw const FormatException('Invalid index');
    }
    final payload = envelope['payload'] as String;
    final expected = _mac(payload);
    final actual = envelope['mac'] as String;
    var difference = expected.length ^ actual.length;
    for (var i = 0; i < expected.length; i++) {
      difference |=
          expected.codeUnitAt(i) ^
          (i < actual.length ? actual.codeUnitAt(i) : 0);
    }
    if (difference != 0) {
      throw const FormatException('Invalid index authentication');
    }
    final data = jsonDecode(payload);
    if (data is! Map ||
        data['version'] != 3 ||
        data['page'] != name ||
        data['library'] != cipher.libraryId ||
        data['scope'] != scope ||
        data['entries'] is! Map ||
        (data['entries'] as Map).length > maxPageEntries ||
        !data.containsKey('next') ||
        (data['next'] != null &&
            (data['next'] is! String ||
                !_pagePattern.hasMatch(data['next'] as String)))) {
      throw const FormatException('Invalid index scope or link');
    }
    final parsed = <String, _Entry>{};
    for (final item in (data['entries'] as Map).entries) {
      if (item.key is! String ||
          !_commitPattern.hasMatch(item.key as String) ||
          item.value is! Map ||
          item.value['versions'] is! List ||
          !_validVersions(item.value['versions'] as List) ||
          item.value['revision'] is! Map) {
        throw const FormatException('Invalid index entry');
      }
      final versions =
          (item.value['versions'] as List).cast<String>().toSet().toList()
            ..sort();
      final entry = _Entry(
        versions,
        SyncRevision.decode(jsonEncode(item.value['revision'])),
      );
      if (_entryBytes(item.key as String, entry) > _payloadBudget) {
        throw const FormatException('Index entry too large');
      }
      parsed[item.key as String] = entry;
    }
    return (entries: parsed, next: data['next'] as String?);
  }

  String _mac(String payload) => cipher.contentFingerprint(
    utf8.encode('better-keep/metadata-index/v3\n$payload'),
  );
}

typedef _Page = ({Map<String, _Entry> entries, String? next});

class _Upload {
  _Upload(this.pages, this.mutation) : position = pages.length - 1;
  final List<Map<String, _Entry>> pages;
  final int mutation;
  int position;
  Uint8List? bytes;
}

class _Entry {
  _Entry(this.versions, this.revision);
  final List<String> versions;
  final SyncRevision revision;
  Map<String, Object?> toJson() => {
    'versions': versions,
    'revision': revision.toJson(),
  };
  late final encoded = canonicalSyncJson(toJson());
  late final bytes = utf8.encode(encoded).length;
}
