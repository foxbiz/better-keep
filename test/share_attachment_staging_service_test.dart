import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/services/file_system_base.dart';
import 'package:better_keep/services/share_attachment_staging_service.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Note.unlockPostAuthenticationOverride = (_, _) async {};
  });

  tearDown(() {
    Note.unlockPostAuthenticationOverride = null;
  });

  test(
    'locked attachments exist as plaintext only for the share lease',
    () async {
      final imageBytes = Uint8List.fromList([1, 2, 3, 4]);
      final audioBytes = Uint8List.fromList([5, 6, 7, 8]);
      final note = Note(
        locked: true,
        content: await encrypt(_content('private'), '2468'),
        attachments: [
          NoteAttachment.image(
            NoteImage(
              src: _dataUri('image/jpeg', imageBytes),
              size: imageBytes.length,
              index: 0,
              aspectRatio: '1:1',
              lastModified: '2026-07-20T00:00:00.000Z',
            ),
          ),
          NoteAttachment.audio(
            NoteRecording(
              src: _dataUri('audio/wav', audioBytes),
              title: '../../private recording',
            ),
          ),
        ],
      );
      await note.unlock('2468');
      final storage = _MemoryFileSystem();
      final service = ShareAttachmentStagingService(
        fileSystem: storage,
        newId: () => 'share-1',
      );

      final lease = await service.stage(note);

      expect(lease.files, hasLength(2));
      expect(
        lease.files.every(
          (file) => file.path.startsWith('/cache/share_attachments/share-1/'),
        ),
        isTrue,
      );
      expect(storage.files[lease.files[0].path], imageBytes);
      expect(storage.files[lease.files[1].path], audioBytes);
      expect(lease.files[1].path, isNot(contains('..')));

      await lease.release();
      await lease.release();
      expect(storage.files, isEmpty);
    },
  );

  test(
    'concurrent leases use isolated directories and cleanup independently',
    () async {
      final bytes = Uint8List.fromList([9, 8, 7]);
      final note = Note(
        attachments: [
          NoteAttachment.audio(
            NoteRecording(src: _dataUri('audio/wav', bytes), title: 'memo'),
          ),
        ],
      );
      final storage = _MemoryFileSystem();
      var id = 0;
      final service = ShareAttachmentStagingService(
        fileSystem: storage,
        newId: () => 'share-${++id}',
      );

      final first = await service.stage(note);
      final second = await service.stage(note);

      expect(first.files.single.path, contains('/share-1/'));
      expect(second.files.single.path, contains('/share-2/'));
      await first.release();
      expect(storage.files.containsKey(first.files.single.path), isFalse);
      expect(storage.files.containsKey(second.files.single.path), isTrue);
      await second.release();
      expect(storage.files, isEmpty);
    },
  );

  test('startup cleanup removes old and new share files only', () async {
    final storage = _MemoryFileSystem()
      ..seed('/cache/share_attachments/legacy.jpg', [1])
      ..seed('/cache/share_attachments/share-1/audio.wav', [2])
      ..seed('/cache/audio_playback/keep.wav', [3])
      ..seed('/cache/unrelated.txt', [4]);
    final service = ShareAttachmentStagingService(fileSystem: storage);

    expect(await service.cleanupStaleFiles(), 2);

    expect(
      storage.files.containsKey('/cache/share_attachments/legacy.jpg'),
      false,
    );
    expect(
      storage.files.containsKey('/cache/share_attachments/share-1/audio.wav'),
      false,
    );
    expect(storage.files['/cache/audio_playback/keep.wav'], [3]);
    expect(storage.files['/cache/unrelated.txt'], [4]);
  });

  test(
    'a partial staging write remains owned by the disposable lease',
    () async {
      final bytes = Uint8List.fromList([7, 7, 7]);
      final note = Note(
        attachments: [
          NoteAttachment.audio(
            NoteRecording(src: _dataUri('audio/wav', bytes)),
          ),
        ],
      );
      final storage = _MemoryFileSystem()..failWrites = true;
      final service = ShareAttachmentStagingService(
        fileSystem: storage,
        newId: () => 'failed-share',
      );

      final lease = await service.stage(note);
      expect(lease.files, isEmpty);
      expect(storage.files, isNotEmpty);

      await lease.release();
      expect(storage.files, isEmpty);
    },
  );
}

String _content(String text) => jsonEncode([
  {'insert': '$text\n'},
]);

String _dataUri(String mime, Uint8List bytes) =>
    'data:$mime;base64,${base64Encode(bytes)}';

class _MemoryFileSystem implements FileSystem {
  final Map<String, Uint8List> files = {};
  final Set<String> directories = {'/', '/cache'};
  bool failWrites = false;

  void seed(String filePath, List<int> bytes) {
    files[filePath] = Uint8List.fromList(bytes);
    var parent = path.dirname(filePath);
    while (parent != '.' && directories.add(parent)) {
      final next = path.dirname(parent);
      if (next == parent) break;
      parent = next;
    }
  }

  @override
  Future<String> get cacheDir async => '/cache';

  @override
  Future<String> get documentDir async => '/documents';

  @override
  Future<void> createDirectory(String directory) async {
    directories.add(directory);
  }

  @override
  Future<void> writeBytes(
    String filePath,
    Uint8List data, {
    bool append = false,
  }) async {
    directories.add(path.dirname(filePath));
    files[filePath] = append && files.containsKey(filePath)
        ? Uint8List.fromList([...files[filePath]!, ...data])
        : Uint8List.fromList(data);
    if (failWrites) throw StateError('injected partial write');
  }

  @override
  Future<Uint8List> readBytes(String filePath) async =>
      Uint8List.fromList(files[filePath] ?? (throw StateError('missing')));

  @override
  Future<bool> delete(String filePath) async => files.remove(filePath) != null;

  @override
  Future<bool> exists(String filePath) async => files.containsKey(filePath);

  @override
  Future<bool> isDirectory(String value) async => directories.contains(value);

  @override
  Future<bool> isFile(String value) async => files.containsKey(value);

  @override
  Future<List<String>> list([String directory = '/']) async {
    final children = <String>{};
    for (final candidate in [...directories, ...files.keys]) {
      if (candidate == directory || !path.isWithin(directory, candidate)) {
        continue;
      }
      final relative = path.relative(candidate, from: directory);
      children.add(path.join(directory, relative.split(path.separator).first));
    }
    return children.toList()..sort();
  }

  @override
  Future<String> copy(String sourcePath, String targetPath) async {
    await writeBytes(targetPath, await readBytes(sourcePath));
    return targetPath;
  }

  @override
  Future<int?> length(String filePath) async => files[filePath]?.length;

  @override
  Future<void> writeString(
    String filePath,
    String data, {
    bool append = false,
  }) => writeBytes(
    filePath,
    Uint8List.fromList(utf8.encode(data)),
    append: append,
  );

  @override
  Future<String> readString(String filePath) async =>
      utf8.decode(await readBytes(filePath));

  @override
  Future<bool> saveToGallery(Uint8List imageBytes, String fileName) async =>
      false;

  @override
  String get backendType => 'memory';

  @override
  bool get opfsSupported => false;

  @override
  Future<List<Map<String, dynamic>>> listRecursive([
    String directory = '/',
  ]) async => const [];

  @override
  Future<Map<String, dynamic>> testOpfs() async => const {};
}
