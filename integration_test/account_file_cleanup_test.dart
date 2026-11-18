import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/scoped_file_system.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerFileCleanupTest();
}

void registerFileCleanupTest() {
  testWidgets(
    'sign-out removes nested provider files only in the active namespace',
    (_) async {
      final fs = await fileSystem();
      const expected = String.fromEnvironment('TEST_STORAGE_BACKEND');
      if (expected.isNotEmpty) expect(fs.backendType, expected);
      final qa = ScopedFileSystem(
        fs,
        directoryName: 'logout-qa-${DateTime.now().microsecondsSinceEpoch}',
      );
      final prefs = await SharedPreferences.getInstance();
      addTearDown(() async {
        await fs.deleteTrees([await qa.documentDir, await qa.cacheDir]);
        for (final key in prefs.getKeys().where(
          (k) => k.startsWith('account_files.${qa.directoryName}.'),
        )) {
          await prefs.remove(key);
        }
      });
      final media = p.join(
        await qa.documentDir,
        'external_sync_media',
        'generation',
        'nested',
        'image',
      );
      final cached = p.join(
        await qa.cacheDir,
        'external_sync',
        'objects',
        'revision',
      );
      final sibling = '${await qa.documentDir}-other';
      addTearDown(() => fs.delete(sibling));
      await fs.writeString(sibling, 'keep');
      await fs.writeString(media, 'image');
      await fs.writeString(cached, 'encrypted');
      final documents = await qa.documentDir;
      final cache = await qa.cacheDir;
      for (var offset = 0; offset < 1000; offset += 16) {
        await Future.wait([
          for (var i = offset; i < offset + 16 && i < 1000; i++)
            fs.writeString(
              p.join(
                i.isEven ? documents : cache,
                '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}.jpg',
              ),
              'QA',
            ),
        ]);
      }
      // A hyphen sorts before '/', and '_' sorts after it. Listing only skips
      // descendants of audio after its first descendant has been encountered.
      await qa.writeString(p.join(documents, 'audio', 'recording.m4a'), 'QA');
      await qa.writeString(p.join(documents, 'audio-x'), 'sibling');
      await qa.writeString(p.join(documents, 'audio_playback', 'clip'), 'QA');
      expect(
        (await qa.list(documents)).map(p.basename),
        containsAll(['audio', 'audio-x', 'audio_playback']),
      );
      final clock = Stopwatch()..start();
      final cleanup = AccountFileCleanup(qa.directoryName, () async => qa);
      final id = const Uuid().v4();
      await cleanup.retire(prefs, id);
      final handoffMs = clock.elapsedMilliseconds;
      final next = cleanup.activeFiles(prefs, qa);
      final nextFile = p.join(
        await next.documentDir,
        'external_sync_media',
        'generation',
        'nested',
        'image',
      );
      await next.writeString(nextFile, 'new account');
      await cleanup.resume(prefs);
      expect(await next.readString(nextFile), 'new account');
      if (const bool.fromEnvironment('SYNC_TIMINGS')) {
        debugPrint(
          'Library handoff ${handoffMs}ms, cleanup and isolation check ${clock.elapsedMilliseconds}ms',
        );
      }
      expect(
        await fs.list(documents),
        unorderedEquals([await next.documentDir, p.join(documents, 'audio-x')]),
      );
      if (cache != documents) expect(await fs.list(cache), isEmpty);
      expect(await fs.exists(media), isFalse);
      expect(await fs.exists(cached), isFalse);
      expect(await fs.readString(sibling), 'keep');
    },
  );
  for (final pointer in ['active', 'backup']) {
    testWidgets(
      'stale $pointer pointer cannot reopen a deleted library after a false retirement marker',
      (_) async {
        final base = await fileSystem();
        final name = 'ownership-qa-${const Uuid().v4()}';
        final root = ScopedFileSystem(base, directoryName: name);
        final prefs = await SharedPreferences.getInstance();
        final key = 'account_files.$name.active';
        final cleanup = AccountFileCleanup(name, () async => root);
        addTearDown(() async {
          await base.deleteTrees([await root.documentDir, await root.cacheDir]);
          for (final k in prefs.getKeys().where(
            (k) => k.startsWith('account_files.$name.'),
          )) {
            await prefs.remove(k);
          }
        });
        final previous = const Uuid().v4();
        final good = const Uuid().v4();
        final next = const Uuid().v4();
        await cleanup.retire(prefs, previous);
        final oldFile = p.join(
          await cleanup.activeFiles(prefs, root).documentDir,
          'same',
        );
        await root.writeString(oldFile, 'old');
        await cleanup.retire(prefs, good);
        final liveFile = p.join(
          await cleanup.activeFiles(prefs, root).documentDir,
          'same',
        );
        await root.writeString(liveFile, 'current');
        final backup = '$key.backup';
        final stale = pointer == 'active' ? key : backup;
        final valid = pointer == 'active' ? backup : key;
        await prefs.setString(stale, previous);
        expect(
          p.join(await cleanup.activeFiles(prefs, root).documentDir, 'same'),
          liveFile,
        );
        await cleanup.resume(prefs);
        expect(await root.exists(oldFile), isFalse);
        expect(prefs.getBool('account_files.$name.retired.$previous'), isFalse);
        expect(await root.readString(liveFile), 'current');
        expect(
          p.join(await cleanup.activeFiles(prefs, root).documentDir, 'same'),
          liveFile,
        );
        // The retired pointer still cannot confer ownership by itself.
        await prefs.remove(valid);
        expect(
          () => cleanup.activeFiles(prefs, root),
          throwsA(isA<LocalLibraryUnavailable>()),
        );
        expect(cleanup.canRotateTo(prefs, previous), isFalse);
        expect(await root.exists(oldFile), isFalse);

        // Two conflicting valid pointers cannot establish ownership.
        await prefs.setString('$key.backup', good);
        await prefs.setString(key, const Uuid().v4());
        expect(
          () => cleanup.activeFiles(prefs, root),
          throwsA(isA<LocalLibraryUnavailable>()),
        );
        await prefs.setString(key, '../unknown');
        await prefs.setString('$key.backup', 'broken');
        expect(
          () => cleanup.activeFiles(prefs, root),
          throwsA(isA<LocalLibraryUnavailable>()),
        );
        await cleanup.retire(prefs, next);
        await cleanup.retire(prefs, next);
        final newFile = p.join(
          await cleanup.activeFiles(prefs, root).documentDir,
          'same',
        );
        expect(await root.exists(newFile), isFalse);
        await root.writeString(newFile, 'new');
        await cleanup.resume(prefs);
        expect(await root.readString(liveFile), 'current');
        expect(await root.readString(newFile), 'new');
        await prefs.remove(key);
        await prefs.remove('$key.backup');
        expect(
          () => cleanup.activeFiles(prefs, root),
          throwsA(isA<LocalLibraryUnavailable>()),
        );
      },
    );
  }
}
