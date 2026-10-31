import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:better_keep/services/file_system_base.dart';
import 'package:better_keep/services/external_sync/firebase_sync_version.dart';
import 'package:better_keep/services/external_sync/file_sync_adapter.dart';
import 'package:better_keep/services/external_sync/sync_revision.dart';
import 'package:better_keep/services/external_sync/sync_cipher.dart';
import 'package:better_keep/services/external_sync/sync_object_cache.dart';
import 'package:better_keep/services/external_sync/sync_mutation_journal.dart';
import 'package:better_keep/services/external_sync/portable_sync_codec.dart';
import 'package:better_keep/services/external_sync/sync_provider_adapter.dart';

Object? legacyCanonical(Object? v) {
  if (v is Map) {
    final keys = v.keys.cast<String>().toList()..sort();
    return {for (final k in keys) k: legacyCanonical(v[k])};
  }
  if (v is List) return v.map(legacyCanonical).toList();
  return v;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncCipher cipher;
  setUp(() async {
    cipher = await SyncCipher.create('synthetic-review', Uint8List(32));
  });
  tearDown(() {
    cipher.dispose();
  });
  test(
    'fallback timestamp changes produce distinct immutable commits',
    () async {
      Map<String, dynamic> body(int second) => {
        'title': 'Legacy',
        'updated_at': '2026-10-24T12:00:00',
        'sync_committed_at': Timestamp.fromDate(
          DateTime.utc(2026, 10, 24, 7, 0, second),
        ),
      };
      final a = FirebaseSyncVersion.read(SyncEntityKind.note, 'note', body(1));
      final b = FirebaseSyncVersion.read(SyncEntityKind.note, 'note', body(2));
      expect(a.revisionId, isNot(b.revisionId));
      expect(a.modifiedAtMicros, isNot(b.modifiedAtMicros));
      SyncRevision material(SyncVersion v) => SyncRevision(
        kind: v.kind,
        entityId: v.entityId,
        revisionId: v.revisionId,
        modifiedAtMicros: v.modifiedAtMicros,
        deleted: false,
        payloadObjectId: 'a' * 64,
        contentFingerprint: 'b' * 64,
      );
      final adapter = FileSyncAdapter(
        connectionId: 'test',
        transport: MemoryFiles(),
        cipher: cipher,
      );
      await adapter.publish(material(a));
      await adapter.publish(material(b));
    },
  );
  for (final ratio in [1.0, 1.5, 1e-7, 1e20]) {
    test(
      'legacy sketch ratio $ratio republishes under its original source revision',
      () async {
        final cache = MemoryCache(cipher);
        final codec = PortableSyncCodec(
          cache: cache,
          readAttachment: (_) async =>
              Uint8List.fromList(utf8.encode('{"strokes":[]}')),
          writeAttachment: (_, _, _, _) async => '/restored.json',
          decryptLocalField: (s) async => s,
          encryptLocalField: (s) async => s,
        );
        final version = SyncLocalVersion(
          kind: SyncEntityKind.note,
          entityId: 'note',
          localId: '1',
          revisionId: 'same-source-edit',
          modifiedAtMicros: 1000000,
          deleted: false,
        );
        final current = await codec.encode(version, {
          'title': 'Drawing',
          'content': '[]',
          'attachments': jsonEncode([
            {
              'type': 'sketch',
              'data': {
                'aspectRatio': ratio,
                'strokesFilePath': '/drawing.json',
                'bgColor': 4294967295,
                'pagePattern': 'blank',
              },
            },
          ]),
        });
        final payload = jsonDecode(
          utf8.decode(await cache.decrypt(current.payloadObjectId!)),
        ) as Map;
        final normalized = jsonDecode(jsonEncode(payload)) as Map;
        final source = normalized['data']['attachments'][0]['data'] as Map;
        source['strokesFilePath'] = {
          'contentHash': source['strokesFilePath']['contentHash'],
        };
        final oldFingerprint = cipher.contentFingerprint(
          utf8.encode(jsonEncode(legacyCanonical(normalized))),
        );
        final old = SyncRevision(
          kind: current.kind,
          entityId: current.entityId,
          revisionId: current.revisionId,
          modifiedAtMicros: current.modifiedAtMicros,
          deleted: false,
          payloadObjectId: current.payloadObjectId,
          blobIds: current.blobIds,
          contentFingerprint: oldFingerprint,
        );
        // Non-integral canonical encoding deliberately differs from legacy JSON.
        await codec.decode(old);
        expect(old.sameContent(current), true);
        expect(SyncRevision.decode(current.encode()).sameContent(old), true);
        final adapter = FileSyncAdapter(
          connectionId: 'test',
          transport: MemoryFiles(),
          cipher: cipher,
        );
        await adapter.publish(old);
        await adapter.publish(current);
        final files = MemoryFiles();
        files.objects[FileSyncAdapter.objectName(current.payloadObjectId!)] =
            cache.objects[current.payloadObjectId!]!;
        final upgrading = FileSyncAdapter(
          connectionId: 'upgrade',
          transport: files,
          cipher: cipher,
          normalizeLegacyRevision: (revision, read) async =>
              PortableSyncCodec.normalizeFingerprint(
                cipher,
                revision,
                await cipher.decryptObject(
                  await read(revision.payloadObjectId!),
                ),
              ),
        );
        await upgrading.publish(old);
        final originalCommit = files.objects[FileSyncAdapter.commitName(old)]!;
        // Both versions already existed before this upgrade, with no aliases.
        final canonicalBeforeUpgrade = SyncRevision.decode(
          jsonEncode(
            {...current.toJson()}..remove('legacyContentFingerprints'),
          ),
        );
        await upgrading.publish(canonicalBeforeUpgrade);
        expect(
          files.objects[FileSyncAdapter.commitName(old)],
          same(originalCommit),
        );
        final listed = (await upgrading.changes(null)).revisions.single;
        expect(listed.sameContent(old), true);
        expect(listed.sameContent(canonicalBeforeUpgrade), true);
        final forged = SyncRevision.decode(
          jsonEncode({
            ...current.toJson(),
            'legacyContentFingerprints': ['f' * 64],
          }),
        );
        await expectLater(codec.decode(forged), throwsFormatException);
        final changed = await codec.encode(version, {
          'title': 'Different content',
          'content': '[]',
        });
        expect(old.sameContent(changed), false);
        await expectLater(
          adapter.publish(changed),
          throwsA(isA<SyncProviderFailure>()),
        );
      },
    );
  }
}

class MemoryFiles implements SyncFileTransport {
  final objects = <String, Uint8List>{};
  @override
  Future<bool> create(String n, Uint8List b) async {
    if (objects.containsKey(n)) return false;
    objects[n] = b;
    return true;
  }

  @override
  Future<Uint8List> read(String n) async => objects[n]!;
  @override
  Future<SyncFilePage> list(String? c) async =>
      SyncFilePage(names: objects.keys.toList(), cursor: null, hasMore: false);
}

class UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('No database access');
}

class UnusedFiles implements FileSystem {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('No filesystem access');
}

class MemoryCache extends SyncObjectCache {
  MemoryCache(SyncCipher cipher)
    : super(
        database: UnusedDatabase(),
        files: UnusedFiles(),
        root: '/unused',
        scope: 'test',
        cipher: cipher,
      );
  final objects = <String, Uint8List>{};
  @override
  Future<String> encrypt(Uint8List bytes) async {
    final encrypted = await cipher.encryptObject(bytes);
    final id = sha256.convert(encrypted).toString();
    objects[id] = encrypted;
    return id;
  }

  @override
  Future<Uint8List> decrypt(String id) async =>
      cipher.decryptObject(objects[id]!);
}
