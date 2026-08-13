import 'dart:typed_data';

import 'package:better_keep/services/audio_playback_source_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('plaintext local audio keeps its original device path', () async {
    final files = _FakeAudioFiles()..raw['/docs/audio.wav'] = _wavBytes();
    final service = AudioPlaybackSourceService(operations: files.operations);

    final lease = await service.resolve(
      '/docs/audio.wav',
      protectedSource: true,
    );

    expect(lease.kind, AudioPlaybackSourceKind.deviceFile);
    expect(lease.location, '/docs/audio.wav');
    expect(lease.mimeType, 'audio/wav');
    expect(lease.isTemporary, isFalse);
    expect(files.writes, isEmpty);
    await lease.release();
    expect(files.raw, contains('/docs/audio.wav'));
  });

  test('remote audio is supported only for unprotected sources', () async {
    final service = AudioPlaybackSourceService(
      operations: _FakeAudioFiles().operations,
    );

    final lease = await service.resolve(
      'https://example.com/audio.m4a',
      protectedSource: false,
    );
    expect(lease.kind, AudioPlaybackSourceKind.url);
    expect(lease.mimeType, 'audio/mp4');

    await expectLater(
      service.resolve('https://example.com/audio.m4a', protectedSource: true),
      throwsA(
        isA<AudioPlaybackSourceException>().having(
          (error) => error.code,
          'code',
          AudioPlaybackSourceError.protectedRemote,
        ),
      ),
    );
  });

  test(
    'unlocked ENCR audio receives a verified ephemeral plaintext copy',
    () async {
      final encrypted = Uint8List.fromList([0x45, 0x4e, 0x43, 0x52, 1, 2, 3]);
      final plaintext = _wavBytes();
      final files = _FakeAudioFiles()
        ..raw['/docs/locked-audio.wav'] = encrypted
        ..decrypted['/docs/locked-audio.wav'] = plaintext;
      final service = AudioPlaybackSourceService(operations: files.operations);

      final first = await service.resolve(
        '/docs/locked-audio.wav',
        protectedSource: true,
      );
      final second = await service.resolve(
        '/docs/locked-audio.wav',
        protectedSource: true,
      );

      expect(first.kind, AudioPlaybackSourceKind.deviceFile);
      expect(first.isTemporary, isTrue);
      expect(first.location, endsWith('.wav'));
      expect(second.location, isNot(first.location));
      expect(files.raw[first.location], plaintext);
      expect(files.raw['/docs/locked-audio.wav'], encrypted);

      await first.release();
      await first.release();
      expect(files.raw, isNot(contains(first.location)));
      expect(files.deleteCalls.where((value) => value == first.location), [
        first.location,
      ]);
      expect(files.raw, contains('/docs/locked-audio.wav'));
      await second.release();
    },
  );

  test(
    'authenticated decoder opens raw ENCP without changing its source',
    () async {
      final protectedBytes = Uint8List.fromList([
        0x45,
        0x4e,
        0x43,
        0x50,
        1,
        2,
        3,
      ]);
      final plaintext = _wavBytes();
      final files = _FakeAudioFiles()
        ..raw['/docs/protected.wav'] = Uint8List.fromList(protectedBytes);
      final service = AudioPlaybackSourceService(operations: files.operations);
      Uint8List? decoderInput;

      final lease = await service.resolve(
        '/docs/protected.wav',
        protectedSource: true,
        passwordProtectedDecoder: (bytes) async {
          decoderInput = bytes;
          return plaintext;
        },
      );

      expect(decoderInput, protectedBytes);
      expect(decoderInput, same(files.rawReadBuffers.first));
      expect(lease.isTemporary, isTrue);
      expect(files.raw[lease.location], plaintext);
      expect(files.raw['/docs/protected.wav'], protectedBytes);

      await lease.release();
      expect(files.raw, contains('/docs/protected.wav'));
      expect(files.raw, isNot(contains(lease.location)));
    },
  );

  test('authenticated decoder opens ENCR-wrapped ENCP audio', () async {
    final localWrapper = Uint8List.fromList([0x45, 0x4e, 0x43, 0x52, 9]);
    final protectedBytes = Uint8List.fromList([0x45, 0x4e, 0x43, 0x50, 4, 5]);
    final plaintext = _wavBytes();
    final files = _FakeAudioFiles()
      ..raw['/docs/wrapped.wav'] = localWrapper
      ..decrypted['/docs/wrapped.wav'] = protectedBytes;
    final service = AudioPlaybackSourceService(operations: files.operations);

    final lease = await service.resolve(
      '/docs/wrapped.wav',
      protectedSource: true,
      passwordProtectedDecoder: (bytes) async {
        expect(bytes, protectedBytes);
        return plaintext;
      },
    );

    expect(lease.isTemporary, isTrue);
    expect(files.raw[lease.location], plaintext);
    expect(files.raw['/docs/wrapped.wav'], localWrapper);
    await lease.release();
  });

  test('web playback uses decrypted bytes without a temporary file', () async {
    final plaintext = _wavBytes();
    final files = _FakeAudioFiles()
      ..raw['/opfs/audio.wav'] = Uint8List.fromList([0x45, 0x4e, 0x43, 0x52])
      ..decrypted['/opfs/audio.wav'] = plaintext;
    final service = AudioPlaybackSourceService(
      operations: files.operations,
      isWeb: true,
    );

    final lease = await service.resolve(
      '/opfs/audio.wav',
      protectedSource: true,
    );

    expect(lease.kind, AudioPlaybackSourceKind.bytes);
    expect(lease.bytes, plaintext);
    expect(files.writes, isEmpty);
  });

  test(
    'web playback decodes password protection only when authorized',
    () async {
      final protectedBytes = Uint8List.fromList([0x45, 0x4e, 0x43, 0x50, 7]);
      final plaintext = _wavBytes();
      final files = _FakeAudioFiles()
        ..raw['/opfs/protected.wav'] = protectedBytes;
      final service = AudioPlaybackSourceService(
        operations: files.operations,
        isWeb: true,
      );

      final lease = await service.resolve(
        '/opfs/protected.wav',
        protectedSource: true,
        passwordProtectedDecoder: (_) async => plaintext,
      );

      expect(lease.kind, AudioPlaybackSourceKind.bytes);
      expect(lease.bytes, plaintext);
      expect(files.writes, isEmpty);
      expect(files.raw['/opfs/protected.wav'], protectedBytes);
    },
  );

  test(
    'ENCP and failed local decryption never become player sources',
    () async {
      final protected = _FakeAudioFiles()
        ..raw['/docs/protected.wav'] = Uint8List.fromList([
          0x45,
          0x4e,
          0x43,
          0x50,
          0xff,
        ]);
      final protectedService = AudioPlaybackSourceService(
        operations: protected.operations,
      );

      await expectLater(
        protectedService.resolve('/docs/protected.wav', protectedSource: true),
        throwsA(
          isA<AudioPlaybackSourceException>().having(
            (error) => error.code,
            'code',
            AudioPlaybackSourceError.passwordProtected,
          ),
        ),
      );
      expect(protected.writes, isEmpty);

      final empty = _FakeAudioFiles()
        ..raw['/docs/empty.wav'] = Uint8List.fromList([0x45, 0x4e, 0x43, 0x52])
        ..decrypted['/docs/empty.wav'] = Uint8List(0);
      await expectLater(
        AudioPlaybackSourceService(
          operations: empty.operations,
        ).resolve('/docs/empty.wav', protectedSource: true),
        throwsA(
          isA<AudioPlaybackSourceException>().having(
            (error) => error.code,
            'code',
            AudioPlaybackSourceError.decryptionFailed,
          ),
        ),
      );
      expect(empty.writes, isEmpty);
    },
  );

  test('failed temp verification removes the unreferenced plaintext', () async {
    final files = _FakeAudioFiles(corruptWrites: true)
      ..raw['/docs/audio.wav'] = Uint8List.fromList([0x45, 0x4e, 0x43, 0x52])
      ..decrypted['/docs/audio.wav'] = _wavBytes();
    final service = AudioPlaybackSourceService(operations: files.operations);

    await expectLater(
      service.resolve('/docs/audio.wav', protectedSource: true),
      throwsA(
        isA<AudioPlaybackSourceException>().having(
          (error) => error.code,
          'code',
          AudioPlaybackSourceError.verificationFailed,
        ),
      ),
    );

    expect(
      files.raw.keys.where(
        (value) => value.startsWith('/cache/audio_playback'),
      ),
      isEmpty,
    );
    expect(files.raw, contains('/docs/audio.wav'));
  });

  test('temporary write failures are reported as unreadable audio', () async {
    final files = _FakeAudioFiles(writeError: StateError('disk unavailable'))
      ..raw['/docs/audio.wav'] = Uint8List.fromList([0x45, 0x4e, 0x43, 0x52])
      ..decrypted['/docs/audio.wav'] = _wavBytes();
    final service = AudioPlaybackSourceService(operations: files.operations);

    await expectLater(
      service.resolve('/docs/audio.wav', protectedSource: true),
      throwsA(
        isA<AudioPlaybackSourceException>()
            .having(
              (error) => error.code,
              'code',
              AudioPlaybackSourceError.unreadable,
            )
            .having((error) => error.cause, 'cause', isA<StateError>()),
      ),
    );

    expect(
      files.raw.keys.where(
        (value) => value.startsWith('/cache/audio_playback'),
      ),
      isEmpty,
    );
  });

  test(
    'startup cleanup is restricted to the playback cache directory',
    () async {
      final files = _FakeAudioFiles()
        ..raw['/cache/audio_playback/stale-1.wav'] = _wavBytes()
        ..raw['/cache/audio_playback/stale-2.m4a'] = _wavBytes()
        ..raw['/cache/unrelated.tmp'] = Uint8List.fromList([1]);
      final service = AudioPlaybackSourceService(operations: files.operations);

      expect(await service.cleanupStaleFiles(), 2);
      expect(files.raw, isNot(contains('/cache/audio_playback/stale-1.wav')));
      expect(files.raw, isNot(contains('/cache/audio_playback/stale-2.m4a')));
      expect(files.raw, contains('/cache/unrelated.tmp'));
    },
  );

  test('extension and MIME inference use safe bounded values', () {
    expect(AudioPlaybackSourceService.safeExtension('/a/voice.WAV'), '.wav');
    expect(
      AudioPlaybackSourceService.safeExtension('/a/no-extension'),
      '.audio',
    );
    expect(
      AudioPlaybackSourceService.safeExtension('/a/file.verylongextension'),
      '.audio',
    );
    expect(
      AudioPlaybackSourceService.mimeTypeFor('/a/voice.mp3'),
      'audio/mpeg',
    );
    expect(AudioPlaybackSourceService.mimeTypeFor('/a/voice.bin'), isNull);
  });
}

Uint8List _wavBytes() => Uint8List.fromList([
  0x52,
  0x49,
  0x46,
  0x46,
  0x04,
  0x00,
  0x00,
  0x00,
  0x57,
  0x41,
  0x56,
  0x45,
]);

class _FakeAudioFiles {
  final bool corruptWrites;
  final Object? writeError;
  final Map<String, Uint8List> raw = {};
  final Map<String, Uint8List> decrypted = {};
  final List<String> writes = [];
  final List<String> deleteCalls = [];
  final List<Uint8List> rawReadBuffers = [];
  int _nextId = 0;

  _FakeAudioFiles({this.corruptWrites = false, this.writeError});

  late final AudioPlaybackFileOperations operations =
      AudioPlaybackFileOperations(
        fixPath: (source) async => source,
        exists: (filePath) async => raw.containsKey(filePath),
        readPrefix: (filePath, length) async {
          final bytes = raw[filePath]!;
          return Uint8List.fromList(bytes.take(length).toList(growable: false));
        },
        readRaw: (filePath) async {
          final bytes = Uint8List.fromList(raw[filePath]!);
          rawReadBuffers.add(bytes);
          return bytes;
        },
        readDecrypted: (filePath) async =>
            Uint8List.fromList(decrypted[filePath] ?? raw[filePath]!),
        writeRaw: (filePath, bytes) async {
          writes.add(filePath);
          if (writeError != null) throw writeError!;
          raw[filePath] = corruptWrites
              ? Uint8List.fromList([...bytes, 0xff])
              : Uint8List.fromList(bytes);
        },
        delete: (filePath) async {
          deleteCalls.add(filePath);
          return raw.remove(filePath) != null;
        },
        length: (filePath) async => raw[filePath]?.length,
        cacheDirectory: () async => '/cache',
        createDirectory: (_) async {},
        list: (directory) async => raw.keys
            .where((filePath) => path.dirname(filePath) == directory)
            .toList(),
        isFile: (filePath) async => raw.containsKey(filePath),
        newId: () => 'generated-${++_nextId}',
      );
}
