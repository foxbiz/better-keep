import 'package:better_keep/services/audio_file_prefix_reader.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/file_utils.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

enum AudioPlaybackSourceKind { url, deviceFile, bytes }

enum AudioPlaybackSourceError {
  emptySource,
  missing,
  protectedRemote,
  passwordProtected,
  decryptionFailed,
  verificationFailed,
  unreadable,
}

class AudioPlaybackSourceException implements Exception {
  final AudioPlaybackSourceError code;
  final String message;
  final Object? cause;

  const AudioPlaybackSourceException(this.code, this.message, [this.cause]);

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

/// A prepared source owned by one audio player.
///
/// [release] is idempotent and removes only a temporary playback copy created
/// by [AudioPlaybackSourceService]. It never deletes the attachment source.
class AudioPlaybackSourceLease {
  final AudioPlaybackSourceKind kind;
  final String? location;
  final Uint8List? bytes;
  final String? mimeType;
  final bool isTemporary;
  final Future<void> Function()? _release;
  Future<void>? _releaseFuture;

  AudioPlaybackSourceLease._({
    required this.kind,
    this.location,
    this.bytes,
    this.mimeType,
    this.isTemporary = false,
    this._release,
  });

  factory AudioPlaybackSourceLease.url(String value, {String? mimeType}) =>
      AudioPlaybackSourceLease._(
        kind: AudioPlaybackSourceKind.url,
        location: value,
        mimeType: mimeType,
      );

  factory AudioPlaybackSourceLease.deviceFile(
    String value, {
    String? mimeType,
    bool isTemporary = false,
    Future<void> Function()? release,
  }) => AudioPlaybackSourceLease._(
    kind: AudioPlaybackSourceKind.deviceFile,
    location: value,
    mimeType: mimeType,
    isTemporary: isTemporary,
    release: release,
  );

  factory AudioPlaybackSourceLease.bytes(Uint8List value, {String? mimeType}) =>
      AudioPlaybackSourceLease._(
        kind: AudioPlaybackSourceKind.bytes,
        bytes: value,
        mimeType: mimeType,
      );

  Future<void> release() =>
      _releaseFuture ??= Future<void>.sync(() async => _release?.call());
}

typedef AudioPlaybackResolve =
    Future<AudioPlaybackSourceLease> Function(
      String source, {
      required bool protectedSource,
    });

typedef PasswordProtectedAudioDecoder =
    Future<Uint8List> Function(Uint8List protectedBytes);

@immutable
class AudioPlaybackFileOperations {
  final Future<String> Function(String source) fixPath;
  final Future<bool> Function(String filePath) exists;
  final Future<Uint8List> Function(String filePath, int length) readPrefix;
  final Future<Uint8List> Function(String filePath) readRaw;
  final Future<Uint8List> Function(String filePath) readDecrypted;
  final Future<void> Function(String filePath, Uint8List bytes) writeRaw;
  final Future<bool> Function(String filePath) delete;
  final Future<int?> Function(String filePath) length;
  final Future<String> Function() cacheDirectory;
  final Future<void> Function(String directory) createDirectory;
  final Future<List<String>> Function(String directory) list;
  final Future<bool> Function(String filePath) isFile;
  final String Function() newId;

  const AudioPlaybackFileOperations({
    required this.fixPath,
    required this.exists,
    required this.readPrefix,
    required this.readRaw,
    required this.readDecrypted,
    required this.writeRaw,
    required this.delete,
    required this.length,
    required this.cacheDirectory,
    required this.createDirectory,
    required this.list,
    required this.isFile,
    required this.newId,
  });

  static Future<AudioPlaybackFileOperations> platform() async {
    final fs = await fileSystem();
    return AudioPlaybackFileOperations(
      fixPath: FileUtils.fixPath,
      exists: fs.exists,
      readPrefix: readAudioFilePrefix,
      readRaw: fs.readBytes,
      readDecrypted: readEncryptedBytes,
      writeRaw: (filePath, bytes) => fs.writeBytes(filePath, bytes),
      delete: fs.delete,
      length: fs.length,
      cacheDirectory: () => fs.cacheDir,
      createDirectory: fs.createDirectory,
      list: fs.list,
      isFile: fs.isFile,
      newId: () => const Uuid().v4(),
    );
  }
}

/// Resolves attachment storage into media-player-safe sources without changing
/// the stored attachment path or weakening encryption at rest.
class AudioPlaybackSourceService {
  static const cacheSubdirectory = 'audio_playback';

  final AudioPlaybackFileOperations operations;
  final bool isWeb;

  const AudioPlaybackSourceService({
    required this.operations,
    this.isWeb = kIsWeb,
  });

  static Future<AudioPlaybackSourceService> platform() async =>
      AudioPlaybackSourceService(
        operations: await AudioPlaybackFileOperations.platform(),
      );

  Future<AudioPlaybackSourceLease> resolve(
    String source, {
    required bool protectedSource,
    PasswordProtectedAudioDecoder? passwordProtectedDecoder,
  }) async {
    if (source.isEmpty) {
      throw const AudioPlaybackSourceException(
        AudioPlaybackSourceError.emptySource,
        'Audio source is empty',
      );
    }

    final mimeType = mimeTypeFor(source);
    if (_isRemote(source)) {
      if (protectedSource) {
        throw const AudioPlaybackSourceException(
          AudioPlaybackSourceError.protectedRemote,
          'Protected audio must be downloaded before playback',
        );
      }
      return AudioPlaybackSourceLease.url(source, mimeType: mimeType);
    }

    try {
      final fixedPath = await operations.fixPath(source);
      if (!await operations.exists(fixedPath)) {
        throw const AudioPlaybackSourceException(
          AudioPlaybackSourceError.missing,
          'Audio file is unavailable',
        );
      }

      if (isWeb) {
        final storedBytes = await operations.readDecrypted(fixedPath);
        final decoded = await _decodePasswordProtection(
          storedBytes,
          decoder: protectedSource ? passwordProtectedDecoder : null,
        );
        return AudioPlaybackSourceLease.bytes(decoded, mimeType: mimeType);
      }

      final prefix = await operations.readPrefix(fixedPath, 4);
      if (isBytesPasswordEncrypted(prefix)) {
        final protectedBytes = await operations.readRaw(fixedPath);
        final decoded = await _decodePasswordProtection(
          protectedBytes,
          decoder: protectedSource ? passwordProtectedDecoder : null,
        );
        return _writeTemporarySource(
          originalSource: fixedPath,
          decoded: decoded,
          mimeType: mimeType,
        );
      }

      if (!LocalDataEncryption.isBytesEncrypted(prefix)) {
        final fileLength = await operations.length(fixedPath);
        if (fileLength == null || fileLength <= 0) {
          throw const AudioPlaybackSourceException(
            AudioPlaybackSourceError.unreadable,
            'Audio file is empty',
          );
        }
        return AudioPlaybackSourceLease.deviceFile(
          fixedPath,
          mimeType: mimeType,
        );
      }

      final storedBytes = await operations.readDecrypted(fixedPath);
      final decoded = await _decodePasswordProtection(
        storedBytes,
        decoder: protectedSource ? passwordProtectedDecoder : null,
      );
      return _writeTemporarySource(
        originalSource: fixedPath,
        decoded: decoded,
        mimeType: mimeType,
      );
    } on AudioPlaybackSourceException {
      rethrow;
    } catch (error) {
      throw AudioPlaybackSourceException(
        AudioPlaybackSourceError.unreadable,
        'Audio source could not be prepared',
        error,
      );
    }
  }

  Future<Uint8List> _decodePasswordProtection(
    Uint8List storedBytes, {
    PasswordProtectedAudioDecoder? decoder,
  }) async {
    var decoded = storedBytes;
    if (isBytesPasswordEncrypted(decoded)) {
      if (decoder == null) {
        throw const AudioPlaybackSourceException(
          AudioPlaybackSourceError.passwordProtected,
          'Audio file is still password-protected',
        );
      }
      try {
        decoded = await decoder(Uint8List.fromList(decoded));
      } catch (error) {
        throw AudioPlaybackSourceException(
          AudioPlaybackSourceError.decryptionFailed,
          'Authenticated audio decryption failed',
          error,
        );
      }
    }
    _validateDecoded(decoded);
    return decoded;
  }

  Future<int> cleanupStaleFiles() async {
    final directory = await _cacheDirectory();
    var deleted = 0;
    for (final entry in await operations.list(directory)) {
      try {
        if (await operations.isFile(entry) && await operations.delete(entry)) {
          deleted++;
        }
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to remove stale audio playback file',
          error,
          stackTrace,
        );
      }
    }
    return deleted;
  }

  Future<AudioPlaybackSourceLease> _writeTemporarySource({
    required String originalSource,
    required Uint8List decoded,
    required String? mimeType,
  }) async {
    final directory = await _cacheDirectory();
    await operations.createDirectory(directory);
    final extension = safeExtension(originalSource);
    final temporaryPath = path.join(
      directory,
      '${operations.newId()}$extension',
    );

    try {
      await operations.writeRaw(temporaryPath, decoded);
      final verified = await operations.readRaw(temporaryPath);
      if (!listEquals(verified, decoded)) {
        throw const AudioPlaybackSourceException(
          AudioPlaybackSourceError.verificationFailed,
          'Temporary audio changed while being written',
        );
      }
      return AudioPlaybackSourceLease.deviceFile(
        temporaryPath,
        mimeType: mimeType,
        isTemporary: true,
        release: () async {
          try {
            if (await operations.exists(temporaryPath)) {
              await operations.delete(temporaryPath);
            }
          } catch (error, stackTrace) {
            AppLogger.error(
              'Failed to remove temporary audio playback file',
              error,
              stackTrace,
            );
          }
        },
      );
    } catch (_) {
      if (await operations.exists(temporaryPath)) {
        await operations.delete(temporaryPath);
      }
      rethrow;
    }
  }

  void _validateDecoded(Uint8List decoded) {
    if (decoded.isEmpty) {
      throw const AudioPlaybackSourceException(
        AudioPlaybackSourceError.decryptionFailed,
        'Audio decryption produced no data',
      );
    }
    if (isBytesPasswordEncrypted(decoded)) {
      throw const AudioPlaybackSourceException(
        AudioPlaybackSourceError.passwordProtected,
        'Audio file is still password-protected',
      );
    }
    if (LocalDataEncryption.isBytesEncrypted(decoded)) {
      throw const AudioPlaybackSourceException(
        AudioPlaybackSourceError.decryptionFailed,
        'Audio file still contains local encryption',
      );
    }
  }

  Future<String> _cacheDirectory() async =>
      path.join(await operations.cacheDirectory(), cacheSubdirectory);

  @visibleForTesting
  static String safeExtension(String source) {
    final extension = path.extension(source).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension)
        ? extension
        : '.audio';
  }

  @visibleForTesting
  static String? mimeTypeFor(String source) {
    return switch (path.extension(source).toLowerCase()) {
      '.wav' || '.wave' => 'audio/wav',
      '.m4a' || '.mp4' => 'audio/mp4',
      '.aac' => 'audio/aac',
      '.mp3' => 'audio/mpeg',
      '.ogg' || '.oga' => 'audio/ogg',
      '.opus' => 'audio/opus',
      '.flac' => 'audio/flac',
      _ => null,
    };
  }

  static bool _isRemote(String source) =>
      source.startsWith('http://') || source.startsWith('https://');
}
