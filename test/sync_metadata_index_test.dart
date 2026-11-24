import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_metadata_index.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SyncCipher cipher;
  late _Files files;
  SyncRevision revision(String id, {int time = 1}) => SyncRevision(
    kind: SyncEntityKind.note,
    entityId: id,
    revisionId: 'revision-$id',
    modifiedAtMicros: time,
    deleted: false,
    payloadObjectId: 'a' * 64,
  );
  FileSyncAdapter adapter({
    String scope = 'provider-account',
    DateTime Function()? now,
  }) => FileSyncAdapter(
    connectionId: scope,
    transport: files,
    cipher: cipher,
    now: now,
  );
  Future<String> add(SyncRevision value) async {
    final name = FileSyncAdapter.commitName(value);
    files.commits[name] = [await cipher.encodeCommit(value)];
    files.versions[name] = ['version-1'];
    return name;
  }

  setUp(() async {
    cipher = await SyncCipher.create('qa', Uint8List(32));
    files = _Files();
  });
  tearDown(() => cipher.dispose());

  for (final corrupt in [false, true]) {
    test(
      'full scan repairs a ${corrupt ? "corrupt" : "deleted"} cache in the same session',
      () async {
        await add(revision('one'));
        final current = adapter();
        await current.changes(null);
        await current.maintainIndex();
        files.index = corrupt ? Uint8List.fromList([123]) : null;
        await current.changes('end');
        expect(files.indexReads, 1, reason: 'Incremental checks do not reload');
        await current.changes(null);
        expect(files.indexReads, 2);
        expect(
          files.commitReads,
          1,
          reason:
              'Authenticated in-memory entries still match current versions',
        );
        await current.maintainIndex();
        expect(files.writes, 2);
        final repaired = SyncMetadataIndex(cipher, 'provider-account')
          ..load(files.index!);
        expect(repaired.names, hasLength(1));
      },
    );
  }

  test(
    'retained cache checks versions and waits for a complete repair scan',
    () async {
      final unchanged = await add(revision('unchanged'));
      final removed = await add(revision('removed'));
      final changed = await add(revision('changed'));
      final current = adapter();
      await current.changes(null);
      await current.maintainIndex();
      expect(files.commitReads, 3);
      files.index = null;
      files.commits.remove(removed);
      files.versions[changed] = ['version-2'];
      files.commits[changed] = [
        await cipher.encodeCommit(revision('changed', time: 2)),
      ];
      files.listPage = (cursor) => SyncFilePage(
        names: cursor == null ? [unchanged] : [changed],
        cursor: cursor == null ? 'page2' : 'end',
        hasMore: cursor == null,
        commitVersions: files.versions,
      );
      expect(
        (await current.changes(null)).revisions.single.entityId,
        'unchanged',
      );
      await current.maintainIndex();
      expect(
        files.writes,
        1,
        reason: 'An incomplete scan cannot republish retained metadata',
      );
      expect(files.commitReads, 3);
      expect(
        (await current.changes('page2')).revisions.single.modifiedAtMicros,
        2,
      );
      expect(
        files.commitReads,
        4,
        reason: 'Changed provider versions still read the commit',
      );
      await current.maintainIndex();
      expect(files.writes, 2);
      final repaired = SyncMetadataIndex(cipher, 'provider-account')
        ..load(files.index!);
      expect(repaired.names, {unchanged, changed});
      expect(repaired.lookup(changed, ['version-2'])?.modifiedAtMicros, 2);
      expect(repaired.lookup(changed, ['version-1']), isNull);
    },
  );

  test(
    'authenticated plaintext index accelerates a fresh scan, not its inventory',
    () async {
      final name = await add(revision('one'));
      final first = adapter();
      expect((await first.changes(null)).revisions.single.entityId, 'one');
      expect(files.commitReads, 1);
      expect(
        files.writes,
        0,
        reason: 'Only the engine can confirm a complete successful restore',
      );
      await first.maintainIndex();
      expect(files.writes, 1);
      final envelope = jsonDecode(utf8.decode(files.index!)) as Map;
      expect(envelope['payload'], contains('payloadObjectId'));
      final second = adapter();
      expect((await second.changes(null)).revisions.single.entityId, 'one');
      expect(files.commitReads, 1);
      expect(
        files.listings,
        2,
        reason: 'The remote inventory is always enumerated',
      );
      await second.maintainIndex();
      expect(files.writes, 1, reason: 'An unchanged cache needs no rewrite');
      files.commits.remove(name);
      expect(
        (await adapter().changes(null)).revisions,
        isEmpty,
        reason: 'Cached metadata cannot resurrect physically absent files',
      );
    },
  );

  test(
    'new old-client commits and changed versions bypass the index',
    () async {
      final name = await add(revision('one'));
      final first = adapter();
      await first.changes(null);
      await first.maintainIndex();
      await add(revision('two'));
      final next = adapter();
      expect((await next.changes(null)).revisions, hasLength(2));
      expect(files.commitReads, 2);
      files.versions[name] = ['version-2'];
      files.commits[name] = [
        Uint8List.fromList([1, 2, 3]),
      ];
      await expectLater(
        adapter().changes(null),
        throwsA(isA<SyncProviderFailure>()),
      );
    },
  );

  test(
    'a new duplicate copy still validates every original and fails on conflict',
    () async {
      final original = revision('one');
      final name = await add(original);
      final first = adapter();
      await first.changes(null);
      await first.maintainIndex();
      files.versions[name]!.add('duplicate-version');
      files.commits[name]!.add(
        await cipher.encodeCommit(revision('one', time: 2)),
      );
      await expectLater(
        adapter().changes(null),
        throwsA(
          isA<SyncProviderFailure>().having(
            (failure) => failure.kind,
            'kind',
            SyncProviderFailureKind.corruptData,
          ),
        ),
      );
    },
  );

  for (final scenario in [
    'tampered',
    'truncated',
    'other-scope',
    'missing-version',
    'unavailable',
  ]) {
    test(
      '$scenario index falls back to original authenticated commits',
      () async {
        final name = await add(revision('one'));
        final first = adapter();
        await first.changes(null);
        await first.maintainIndex();
        switch (scenario) {
          case 'tampered':
            files.index = Uint8List.fromList(
              utf8.encode(
                utf8
                    .decode(files.index!)
                    .replaceAll('revision-one', 'revision-bad'),
              ),
            );
          case 'truncated':
            files.index = Uint8List.fromList([123]);
          case 'missing-version':
            files.versions.remove(name);
          case 'unavailable':
            files.failRead = true;
        }
        final next = adapter(
          scope: scenario == 'other-scope'
              ? 'other-provider'
              : 'provider-account',
        );
        expect((await next.changes(null)).revisions.single.entityId, 'one');
        expect(files.commitReads, 2);
        files.failWrite = true;
        await next
            .maintainIndex(); // An optional cache cannot fail durable sync.
      },
    );
  }

  for (final splitPage in [false, true]) {
    test(
      'equivalent duplicates are not cached across removal: split=$splitPage',
      () async {
        SyncRevision copy(String object) => SyncRevision(
          kind: SyncEntityKind.note,
          entityId: 'duplicate',
          revisionId: 'same',
          modifiedAtMicros: 1,
          deleted: false,
          payloadObjectId: object * 64,
          contentFingerprint: 'f' * 64,
        );
        final name = await add(copy('a'));
        final first = adapter();
        await first.changes(null);
        await first.maintainIndex();
        files.commits[name]!.add(await cipher.encodeCommit(copy('b')));
        files.versions[name] = [if (!splitPage) 'version-1', 'version-2'];
        final duplicates = adapter();
        await duplicates.changes(null);
        await duplicates.maintainIndex();
        expect(
          jsonDecode(
            jsonDecode(utf8.decode(files.index!))['payload'],
          )['entries'],
          isEmpty,
        );
        // Only the second encrypted representation remains. A fresh scan must
        // return its object reference, even though both copies share a fingerprint.
        files.commits[name]!.removeAt(0);
        files.versions[name] = ['version-2'];
        expect(
          (await adapter().changes(null)).revisions.single.payloadObjectId,
          'b' * 64,
        );
        expect(files.commitReads, 3);
      },
    );
  }

  test(
    'idle checks skip the index, then resumed changes update it once',
    () async {
      final current = adapter();
      await current.changes('existing-checkpoint');
      await current.maintainIndex();
      expect(files.indexReads, 0);
      expect(files.writes, 0);
      await add(revision('one'));
      await current.changes('existing-checkpoint');
      await current.maintainIndex();
      expect(files.indexReads, 1);
      expect(
        files.writes,
        0,
        reason: 'A partial inventory cannot seed the index',
      );
      await current.changes(null);
      await current.maintainIndex();
      await current.changes('updated-checkpoint');
      await current.maintainIndex();
      expect(files.indexReads, 1);
      expect(files.writes, 1, reason: 'Unchanged metadata is not rewritten');
      expect((await adapter().changes(null)).revisions.single.entityId, 'one');
      expect(
        files.commitReads,
        1,
        reason: 'A fresh device reuses the updated cache',
      );
    },
  );

  for (final failedRead in [false, true]) {
    test(
      'incremental scan cannot replace an absent/unreadable index: $failedRead',
      () async {
        final firstName = await add(revision('one'));
        final first = adapter();
        await first.changes(null);
        await first.maintainIndex();
        final saved = files.index;
        final secondName = await add(revision('two'));
        files.failRead = failedRead;
        if (!failedRead) files.index = null;
        files.listPage = (cursor) => SyncFilePage(
          names: cursor == null ? [firstName, secondName] : [secondName],
          cursor: 'end',
          hasMore: false,
          commitVersions: files.versions,
        );
        final next = adapter();
        await next.changes('checkpoint');
        await next.maintainIndex();
        expect(files.writes, 1);
        expect(files.index, failedRead ? same(saved) : isNull);
        await next.changes(null);
        await next.maintainIndex();
        expect(files.writes, 2);
        final loaded = SyncMetadataIndex(cipher, 'provider-account')
          ..load(files.index!);
        expect(loaded.names, {firstName, secondName});
      },
    );
  }

  test('loaded index merges a genuine incremental page without losing unchanged entries', () async {
    final one = await add(revision('one'));
    final first = adapter();
    await first.changes(null);
    await first.maintainIndex();
    final two = await add(revision('two'));
    files.listPage = (_) => SyncFilePage(
      names: [two],
      cursor: 'end',
      hasMore: false,
      commitVersions: files.versions,
    );
    final next = adapter();
    await next.changes('checkpoint');
    await next.maintainIndex();
    final loaded = SyncMetadataIndex(cipher, 'provider-account')
      ..load(files.index!);
    expect(loaded.names, {one, two});
    expect(files.commitReads, 2);
  });

  test(
    'pruning waits for the complete inventory and validated maintenance',
    () async {
      final one = await add(revision('one'));
      final removed = await add(revision('removed'));
      final first = adapter();
      await first.changes(null);
      await first.maintainIndex();
      files.commits.remove(removed);
      files.listPage = (cursor) => SyncFilePage(
        names: cursor == null ? [] : [one],
        cursor: cursor == null ? 'page2' : 'end',
        hasMore: cursor == null,
        commitVersions: files.versions,
      );
      final next = adapter();
      await next.changes(null);
      await next.maintainIndex();
      expect(files.writes, 1);
      await next.changes('page2');
      expect(files.writes, 1);
      await next.maintainIndex();
      expect(
        (SyncMetadataIndex(
          cipher,
          'provider-account',
        )..load(files.index!)).names,
        {one},
      );
    },
  );

  test('resuming an incomplete scan cannot prune unobserved entries', () async {
    final one = await add(revision('one'));
    final two = await add(revision('two'));
    final first = adapter();
    await first.changes(null);
    await first.maintainIndex();
    files.listPage = (cursor) => SyncFilePage(
      names: [one],
      cursor: cursor == null ? 'page2' : 'end',
      hasMore: cursor == null,
      commitVersions: files.versions,
    );
    final resumed = adapter();
    await resumed.changes(null);
    await resumed.changes('unrelated-checkpoint');
    await resumed.maintainIndex();
    expect(files.writes, 1);
    expect(
      (SyncMetadataIndex(cipher, 'provider-account')..load(files.index!)).names,
      {one, two},
    );
  });

  test(
    'failed maintenance backs off, retains dirty work, and retries later',
    () async {
      var now = DateTime.utc(2026);
      await add(revision('one'));
      final current = adapter(now: () => now);
      await current.changes(null);
      files.failWrite = true;
      await current.maintainIndex();
      files.failWrite = false;
      await current.changes(null);
      expect(files.indexReads, 1, reason: 'Full scans retain dirty retry work');
      await current.maintainIndex();
      expect(files.writes, 0);
      now = now.add(const Duration(minutes: 5));
      await current.maintainIndex();
      expect(files.writes, 1);
    },
  );

  testWidgets('stalled index write finishes quietly and preserves retry work', (
    tester,
  ) async {
    var now = DateTime.utc(2026);
    await add(revision('one'));
    final current = adapter(now: () => now);
    await current.changes(null);
    final pending = Completer<void>();
    files.beforeWrite = () => pending.future;
    var completed = false;
    final maintenance = current.maintainIndex().then((_) => completed = true);
    await tester.pump();
    expect(completed, false);
    await tester.pump(SyncMetadataIndex.writeTimeout);
    await maintenance;
    expect(completed, true);
    expect(files.writes, 0);
    pending.complete();
    await tester.pump();
    expect(files.writes, 1);
    await current.maintainIndex();
    expect(files.writes, 1, reason: 'Timed-out maintenance backs off');
    files.beforeWrite = null;
    now = now.add(const Duration(minutes: 5));
    await current.maintainIndex();
    expect(
      files.writes,
      2,
      reason: 'Late completion cannot clear dirty retry work',
    );
  });

  testWidgets('a timed-out chained pass resumes after its acknowledged tail', (
    tester,
  ) async {
    final seed = SyncMetadataIndex(cipher, 'provider-account');
    const count = 8200;
    for (var i = 0; i < count; i++) {
      final value = revision('resume-$i');
      final name = FileSyncAdapter.commitName(value);
      seed.remember(name, ['version-1'], value);
      files.commits[name] = []; // Must be satisfied by the authenticated cache.
      files.versions[name] = ['version-1'];
    }
    await seed.upload((name, bytes) => files.writeIndex(bytes, name: name));
    final oldHead = files.index;
    final changed = revision('resume-${count - 1}', time: 2);
    final changedName = FileSyncAdapter.commitName(changed);
    files.commits[changedName] = [await cipher.encodeCommit(changed)];
    files.versions[changedName] = ['version-2'];
    // Change all three pages so the middle write can time out after the tail
    // has been acknowledged. Unchanged pages no longer cause network writes.
    for (final id in [0, 4096]) {
      final value = revision('resume-$id', time: 2);
      final name = FileSyncAdapter.commitName(value);
      files.commits[name] = [await cipher.encodeCommit(value)];
      files.versions[name] = ['version-2'];
    }
    var now = DateTime.utc(2026);
    final current = adapter(now: () => now);
    await current.changes(null);
    final stalled = Completer<void>();
    final attempts = <String>[];
    files.onIndexWrite = (name) async {
      attempts.add(name);
      if (attempts.length == 2) await stalled.future;
    };
    final pass = current.maintainIndex();
    await tester.pump();
    expect(attempts, hasLength(2));
    await tester.pump(SyncMetadataIndex.writeTimeout);
    await pass;
    expect(
      files.index,
      oldHead,
      reason: 'A partial chain cannot replace the head',
    );
    stalled.complete();
    await tester.pump();
    final beforeBackoff = attempts.length;
    await current.maintainIndex();
    expect(attempts.length, beforeBackoff);
    now = now.add(const Duration(minutes: 5));
    await current.maintainIndex();
    expect(attempts.where((name) => name == attempts.first), hasLength(1));
    expect(attempts.last, SyncMetadataIndex.fileName);
    final restored = SyncMetadataIndex(cipher, 'provider-account');
    await restored.loadChain((name) => files.readIndex(name: name));
    expect(restored.names, hasLength(count));
    expect(restored.lookup(changedName, ['version-2'])?.modifiedAtMicros, 2);
  });

  test(
    'missing continuation falls back to commits and repairs only a full scan',
    () async {
      final one = revision('one');
      final two = revision('two');
      final first = await add(one);
      final second = await add(two);
      final seed = SyncMetadataIndex(cipher, 'provider-account')
        ..remember(first, ['version-1'], one);
      for (var i = 0; i < SyncMetadataIndex.maxPageEntries - 1; i++) {
        final value = revision('unused-$i');
        seed.remember(FileSyncAdapter.commitName(value), ['unused'], value);
      }
      seed.remember(second, ['version-1'], two);
      await seed.upload((name, bytes) => files.writeIndex(bytes, name: name));
      files.indexPages.clear();
      final previousWrites = files.writes;
      files.listPage = (_) => SyncFilePage(
        names: [second],
        cursor: 'incremental-end',
        hasMore: false,
        commitVersions: {
          second: ['version-1'],
        },
      );
      final partial = adapter();
      expect(
        (await partial.changes('previous-cursor')).revisions.single.entityId,
        'two',
      );
      await partial.maintainIndex();
      expect(
        files.writes,
        previousWrites,
        reason: 'A broken chain cannot authorize a partial replacement',
      );
      files.listPage = null;
      final full = adapter();
      expect((await full.changes(null)).revisions, hasLength(2));
      await full.maintainIndex();
      expect(files.writes, previousWrites + 1);
      final reads = files.commitReads;
      expect((await adapter().changes(null)).revisions, hasLength(2));
      expect(
        files.commitReads,
        reads,
        reason: 'The full scan repaired the cache',
      );
    },
  );

  test('duplicate tokens cannot hide a missing provider version', () {
    final value = revision('one');
    final name = FileSyncAdapter.commitName(value);
    final index = SyncMetadataIndex(cipher, 'scope')
      ..remember(name, ['a', 'b'], value);
    expect(index.lookup(name, ['a', 'a']), isNull);
    expect(index.lookup(name, ['b', 'a', 'a']), isNotNull);
  });

  test(
    'byte-identical revisions retain changed provider version tokens',
    () async {
      final value = revision('one');
      final name = FileSyncAdapter.commitName(value);
      final index = SyncMetadataIndex(cipher, 'scope')
        ..remember(name, ['v1'], value);
      index.dirty = false;
      index.remember(name, ['v2'], value);
      expect(index.dirty, true);
      Uint8List? bytes;
      await index.upload((_, value) async => bytes = value);
      final restored = SyncMetadataIndex(cipher, 'scope')..load(bytes!);
      expect(restored.lookup(name, ['v2']), isNotNull);
      expect(restored.lookup(name, ['v1']), isNull);
    },
  );

  test('index is bound to the encryption key and provider scope', () async {
    final value = revision('one');
    final index = SyncMetadataIndex(cipher, 'scope')
      ..remember(FileSyncAdapter.commitName(value), ['v1'], value);
    Uint8List? bytes;
    await index.upload((_, value) async => bytes = value);
    final other = await SyncCipher.create(
      'qa',
      Uint8List.fromList(List.filled(32, 1)),
    );
    addTearDown(other.dispose);
    expect(
      () => SyncMetadataIndex(other, 'scope').load(bytes!),
      throwsFormatException,
    );
    expect(
      () => SyncMetadataIndex(cipher, 'other').load(bytes!),
      throwsFormatException,
    );
  });
}

class _Files
    implements SyncFileTransport, SyncFileCopies, SyncIndexFileTransport {
  final commits = <String, List<Uint8List>>{};
  final versions = <String, List<String>>{};
  Uint8List? index;
  final indexPages = <String, Uint8List>{};
  int commitReads = 0, indexReads = 0, writes = 0, listings = 0;
  bool failRead = false, failWrite = false;
  Future<void> Function()? beforeWrite;
  Future<void> Function(String name)? onIndexWrite;
  SyncFilePage Function(String?)? listPage;
  @override
  Future<SyncFilePage> list(String? cursor) async {
    listings++;
    if (listPage != null) return listPage!(cursor);
    return SyncFilePage(
      names: commits.keys.toList(),
      cursor: 'end',
      hasMore: false,
      commitVersions: versions,
    );
  }

  @override
  Future<List<Uint8List>> readCopies(String name) async {
    commitReads++;
    return commits[name]!;
  }

  @override
  Future<Uint8List> read(String name) async => (await readCopies(name)).first;
  @override
  Future<bool> create(String name, Uint8List bytes) async =>
      throw UnimplementedError();
  @override
  Future<Uint8List?> readIndex({
    String name = SyncMetadataIndex.fileName,
  }) async {
    indexReads++;
    if (failRead) throw StateError('Unavailable cache');
    return name == SyncMetadataIndex.fileName ? index : indexPages[name];
  }

  @override
  Future<void> writeIndex(
    Uint8List bytes, {
    String name = SyncMetadataIndex.fileName,
  }) async {
    await onIndexWrite?.call(name);
    await beforeWrite?.call();
    if (failWrite) throw StateError('Unavailable cache');
    writes++;
    if (name == SyncMetadataIndex.fileName) {
      index = bytes;
    } else {
      indexPages[name] = bytes;
    }
  }
}
