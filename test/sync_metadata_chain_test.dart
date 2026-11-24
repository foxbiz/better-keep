import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_json.dart';
import 'package:better_keep/services/external_sync/sync_metadata_index.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SyncCipher cipher;
  late Map<String, Uint8List> files;
  SyncRevision revision(int id, {int time = 1}) => SyncRevision(
    kind: SyncEntityKind.note,
    entityId: 'note-$id',
    revisionId: 'revision-$id',
    modifiedAtMicros: time,
    deleted: false,
    payloadObjectId: 'a' * 64,
  );
  SyncMetadataIndex index(int count, {String version = 'v', int time = 1}) {
    final result = SyncMetadataIndex(cipher, 'scope');
    for (var i = 0; i < count; i++) {
      final value = revision(i, time: time);
      result.remember(FileSyncAdapter.commitName(value), [version], value);
    }
    return result;
  }

  Map<String, dynamic> payload(Uint8List bytes) =>
      jsonDecode(jsonDecode(utf8.decode(bytes))['payload'])
          as Map<String, dynamic>;

  Future<void> write(String name, Uint8List bytes) async {
    expect(bytes.length, lessThanOrEqualTo(SyncMetadataIndex.maxBytes));
    expect(payload(bytes)['page'], name);
    files[name] = bytes;
  }

  Future<SyncMetadataIndex> restore() async {
    final value = SyncMetadataIndex(cipher, 'scope');
    expect(await value.loadChain((name) async => files[name]), true);
    return value;
  }

  Uint8List signed(Map<String, Object?> data) {
    final payload = canonicalSyncJson(data);
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'payload': payload,
          'mac': cipher.contentFingerprint(
            utf8.encode('better-keep/metadata-index/v3\n$payload'),
          ),
        }),
      ),
    );
  }

  setUp(() async {
    cipher = await SyncCipher.create('chain-qa', Uint8List(32));
    files = {};
  });
  tearDown(() => cipher.dispose());

  test(
    'tail update authenticates only its changed page, also after reload',
    () async {
      final counting = _CountingCipher(cipher);
      final source = SyncMetadataIndex(counting, 'scope');
      for (var i = 0; i < 5000; i++) {
        final value = revision(i);
        source.remember(FileSyncAdapter.commitName(value), ['v1'], value);
      }
      await source.upload(write);
      expect(counting.fingerprints, 2);
      final restored = SyncMetadataIndex(counting, 'scope');
      await restored.loadChain((name) async => files[name]);
      expect(counting.fingerprints, 4);
      for (final current in [source, restored]) {
        counting.fingerprints = 0;
        final value = revision(5000);
        current.remember(FileSyncAdapter.commitName(value), ['v2'], value);
        await current.upload(write);
        expect(
          counting.fingerprints,
          1,
          reason: 'Unchanged pages need neither JSON encoding nor HMAC',
        );
        counting.fingerprints = 0;
        current.remember(FileSyncAdapter.commitName(value), [
          'temporary',
        ], value);
        current.remember(FileSyncAdapter.commitName(value), ['v2'], value);
        await current.upload(
          (_, _) async => fail('Reverted entry is unchanged'),
        );
        expect(counting.fingerprints, 0);
      }
    },
  );

  test(
    'more than 8 MiB and 4096 entries round trip without eviction',
    () async {
      const count = 9000;
      final version = 'v' * 900;
      final source = index(count, version: version);
      final order = <String>[];
      await source.upload((name, bytes) async {
        order.add(name);
        await write(name, bytes);
      });
      expect(
        files.values.fold<int>(0, (sum, b) => sum + b.length),
        greaterThan(SyncMetadataIndex.maxBytes),
      );
      expect(files.length, greaterThan(2));
      expect(order.last, SyncMetadataIndex.fileName);
      final restored = await restore();
      expect(restored.names, hasLength(count));
      for (var i = 0; i < count; i++) {
        final value = revision(i);
        expect(
          restored.lookup(FileSyncAdapter.commitName(value), [
            version,
          ])?.entityId,
          value.entityId,
        );
      }
      var writes = 0;
      await source.upload((_, _) async => writes++);
      expect(writes, 0, reason: 'Unchanged chain must not be uploaded again');
    },
  );

  test(
    'failed middle page preserves the head and resumes after acknowledged tail',
    () async {
      await index(1).upload(write);
      final oldHead = files[SyncMetadataIndex.fileName];
      final source = index(8200);
      final attempts = <String, int>{};
      var fail = true;
      Future<void> interrupted(String name, Uint8List bytes) async {
        attempts.update(name, (n) => n + 1, ifAbsent: () => 1);
        if (fail && attempts.length == 2) {
          fail = false;
          throw StateError('Synthetic interrupted upload');
        }
        await write(name, bytes);
      }

      await expectLater(source.upload(interrupted), throwsStateError);
      expect(files[SyncMetadataIndex.fileName], oldHead);
      expect((await restore()).names, hasLength(1));
      final acknowledgedTail = attempts.keys.first;
      await source.upload(interrupted);
      expect(attempts[acknowledgedTail], 1);
      expect((await restore()).names, hasLength(8200));
      expect(source.dirty, false);
    },
  );

  test(
    'changes between upload passes remain dirty for the next snapshot',
    () async {
      final source = index(4100);
      var writes = 0;
      await expectLater(
        source.upload((name, bytes) async {
          if (++writes == 2) throw StateError('Head unavailable');
          await write(name, bytes);
        }),
        throwsStateError,
      );
      final removed = FileSyncAdapter.commitName(revision(0));
      source.forget(removed);
      final added = revision(5000);
      source.remember(FileSyncAdapter.commitName(added), ['v'], added);
      await source.upload(write);
      expect(source.dirty, true);
      expect((await restore()).names, contains(removed));
      await source.upload(write);
      final restored = await restore();
      expect(restored.names, hasLength(4100));
      expect(restored.names, isNot(contains(removed)));
      expect(
        restored.lookup(FileSyncAdapter.commitName(added), ['v'])?.entityId,
        added.entityId,
      );
      expect(source.dirty, false);
    },
  );

  test('concurrent page writes remain version-checked cache hints', () async {
    final a = index(4100);
    final b = index(4100, version: 'new', time: 2);
    Uint8List? lateHead;
    await a.upload((name, bytes) async {
      if (name == SyncMetadataIndex.fileName) {
        lateHead = bytes;
      } else {
        await write(name, bytes);
      }
    });
    await b.upload(write);
    var restored = await restore();
    expect(
      restored.lookup(FileSyncAdapter.commitName(revision(4099)), [
        'new',
      ])?.modifiedAtMicros,
      2,
    );
    await write(SyncMetadataIndex.fileName, lateHead!);
    restored = await restore();
    expect(restored.names, hasLength(4100));
    expect(
      restored.lookup(FileSyncAdapter.commitName(revision(4099)), [
        'new',
      ])?.modifiedAtMicros,
      2,
      reason: 'The later continuation is independently authenticated',
    );
    expect(
      restored.lookup(FileSyncAdapter.commitName(revision(0)), ['new']),
      isNull,
      reason: 'Stale head metadata must miss the current provider version',
    );
  });

  for (final broken in ['missing', 'tampered', 'wrong-scope']) {
    test('$broken continuation cannot expose a partial index', () async {
      await index(4100).upload(write);
      final next =
          payload(files[SyncMetadataIndex.fileName]!)['next'] as String;
      if (broken == 'missing') {
        files.remove(next);
      } else if (broken == 'tampered') {
        files[next] = Uint8List.fromList([123]);
      }
      final target = SyncMetadataIndex(
        cipher,
        broken == 'wrong-scope' ? 'other' : 'scope',
      );
      final existing = revision(9000);
      target.remember(FileSyncAdapter.commitName(existing), ['v'], existing);
      await expectLater(
        target.loadChain((name) async => files[name]),
        throwsFormatException,
      );
      expect(target.names, {FileSyncAdapter.commitName(existing)});
    });
  }

  for (final link in [
    SyncMetadataIndex.fileName,
    '../private',
    'https://example.test/page',
  ]) {
    test('authenticated unsafe or cyclic link is rejected: $link', () async {
      final bytes = signed({
        'version': 3,
        'page': SyncMetadataIndex.fileName,
        'library': cipher.libraryId,
        'scope': 'scope',
        'entries': {},
        'next': link,
      });
      var reads = 0;
      await expectLater(
        SyncMetadataIndex(cipher, 'scope').loadChain((_) async {
          reads++;
          return bytes;
        }),
        throwsFormatException,
      );
      expect(reads, 1, reason: 'Do not follow a redirect/path/root cycle');
    });
  }

  test('authenticated duplicate entries across pages fail closed', () async {
    await index(4100).upload(write);
    final head = payload(files[SyncMetadataIndex.fileName]!);
    final tailName = head['next'] as String;
    final tail = payload(files[tailName]!);
    (head['entries'] as Map).remove((head['entries'] as Map).keys.first);
    final duplicate = (tail['entries'] as Map).entries.first;
    (head['entries'] as Map)[duplicate.key] = duplicate.value;
    files[SyncMetadataIndex.fileName] = signed(head);
    await expectLater(restore(), throwsFormatException);
  });

  test(
    'repeated tail edits and appends write one page without orphan growth',
    () async {
      final source = index(10000);
      await source.upload(write);
      expect(files, hasLength(3));
      final totalBytes = files.values.fold<int>(0, (sum, b) => sum + b.length);
      // Loading a new session must retain enough knowledge to skip unchanged pages.
      var current = await restore();
      for (var pass = 0; pass < 8; pass++) {
        final edited = revision(9999, time: pass + 2);
        current.remember(FileSyncAdapter.commitName(edited), [
          'edit-$pass',
        ], edited);
        final added = revision(10000 + pass);
        current.remember(FileSyncAdapter.commitName(added), ['v'], added);
        final writes = <String>[];
        var uploaded = 0;
        await current.upload((name, bytes) async {
          writes.add(name);
          uploaded += bytes.length;
          await write(name, bytes);
        });
        expect(writes, [SyncMetadataIndex.pageName(2)]);
        expect(uploaded, lessThan(totalBytes ~/ 3));
        expect(
          files,
          hasLength(3),
          reason: 'Reuse page files, not per-edit generations',
        );
        current = await restore();
        expect(current.names, hasLength(10001 + pass));
        expect(
          current.lookup(FileSyncAdapter.commitName(edited), [
            'edit-$pass',
          ])?.modifiedAtMicros,
          pass + 2,
        );
      }
    },
  );

  test(
    'crossing a page boundary writes only the previous tail and new page',
    () async {
      final source = index(8192);
      await source.upload(write);
      final added = revision(8192);
      source.remember(FileSyncAdapter.commitName(added), ['v'], added);
      final writes = <String>[];
      await source.upload((name, bytes) async {
        writes.add(name);
        await write(name, bytes);
      });
      expect(writes, [
        SyncMetadataIndex.pageName(2),
        SyncMetadataIndex.pageName(1),
      ]);
      expect((await restore()).names, hasLength(8193));
    },
  );

  test(
    'authenticated pages cannot be substituted under another page name',
    () async {
      await index(8200).upload(write);
      files[SyncMetadataIndex.pageName(1)] =
          files[SyncMetadataIndex.pageName(2)]!;
      await expectLater(restore(), throwsFormatException);
    },
  );

  test('authenticated continuation cycles fail closed', () async {
    await index(4100).upload(write);
    final name = SyncMetadataIndex.pageName(1);
    final data = payload(files[name]!);
    data['next'] = name;
    files[name] = signed(data);
    await expectLater(restore(), throwsFormatException);
  });

  test(
    'pruning every entry publishes an empty head without losing dirty state',
    () async {
      final source = index(4100);
      await source.upload(write);
      for (final name in source.names) {
        source.forget(name);
      }
      await source.upload(write);
      expect((await restore()).names, isEmpty);
      expect(payload(files[SyncMetadataIndex.fileName]!)['next'], isNull);
    },
  );
}

class _CountingCipher implements SyncCipher {
  _CountingCipher(this.delegate);
  final SyncCipher delegate;
  int fingerprints = 0;
  @override
  String get libraryId => delegate.libraryId;
  @override
  String contentFingerprint(List<int> bytes) {
    fingerprints++;
    return delegate.contentFingerprint(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
