import 'dart:ui' as ui;

import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:better_keep/utils/image_compressor.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

typedef ImageAttachmentCompress =
    Future<Uint8List> Function(
      Uint8List bytes, {
      required int quality,
      required int minWidth,
      required int minHeight,
    });
typedef ImageAttachmentDecode =
    Future<ImageAttachmentDimensions> Function(Uint8List bytes);
typedef ImageAttachmentThumbnail = Future<String?> Function(Uint8List bytes);
typedef ImageAttachmentDirectory = Future<String> Function();
typedef ImageAttachmentWrite =
    Future<void> Function(String filePath, Uint8List bytes);

@immutable
class ImageAttachmentDimensions {
  final int width;
  final int height;

  const ImageAttachmentDimensions({required this.width, required this.height});
}

class PreparedImageAttachment {
  final Uint8List bytes;
  final ImageAttachmentDimensions dimensions;
  final String? blurredThumbnail;
  final UncommittedAttachmentSourceLease sourceLease;

  const PreparedImageAttachment({
    required this.bytes,
    required this.dimensions,
    required this.blurredThumbnail,
    required this.sourceLease,
  });

  String get path => sourceLease.sourcePath;
  int get byteLength => bytes.length;

  Future<void> release() => sourceLease.releaseByCaller();
}

class ImageAttachmentPreparationOperations {
  final ImageAttachmentCompress compress;
  final ImageAttachmentDecode decode;
  final ImageAttachmentThumbnail generateThumbnail;
  final ImageAttachmentDirectory documentDirectory;
  final ImageAttachmentWrite write;
  final AttachmentSourceCleanup cleanup;
  final String Function() newId;

  const ImageAttachmentPreparationOperations({
    required this.compress,
    required this.decode,
    required this.generateThumbnail,
    required this.documentDirectory,
    required this.write,
    required this.cleanup,
    required this.newId,
  });

  factory ImageAttachmentPreparationOperations.platform() =>
      ImageAttachmentPreparationOperations(
        compress:
            (
              bytes, {
              required quality,
              required minWidth,
              required minHeight,
            }) => ImageCompressor.compressWithList(
              bytes,
              quality: quality,
              minWidth: minWidth,
              minHeight: minHeight,
            ),
        decode: _decodeDimensions,
        generateThumbnail: ThumbnailGenerator.generateFromBytes,
        documentDirectory: () async => (await fileSystem()).documentDir,
        write: writeEncryptedBytes,
        cleanup: (sourcePath) async {
          final cleaned = await scheduleUncommittedAttachmentSourceCleanup(
            sourcePath,
          );
          if (!cleaned) {
            AppLogger.log(
              'Deferred cleanup of a prepared image attachment source',
            );
          }
        },
        newId: () => const Uuid().v4(),
      );

  static Future<ImageAttachmentDimensions> _decodeDimensions(
    Uint8List bytes,
  ) async {
    final codec = await ui.instantiateImageCodec(bytes);
    ui.FrameInfo? frame;
    try {
      frame = await codec.getNextFrame();
      return ImageAttachmentDimensions(
        width: frame.image.width,
        height: frame.image.height,
      );
    } finally {
      frame?.image.dispose();
      codec.dispose();
    }
  }
}

class ImageAttachmentPreparationService {
  static const int maxImageBytes = 500 * 1024;

  final ImageAttachmentPreparationOperations operations;

  const ImageAttachmentPreparationService(this.operations);

  factory ImageAttachmentPreparationService.platform() =>
      ImageAttachmentPreparationService(
        ImageAttachmentPreparationOperations.platform(),
      );

  Future<PreparedImageAttachment> prepare({
    required Uint8List sourceBytes,
    required String extension,
    required bool generateBlurredThumbnail,
  }) async {
    final bytes = await _compressToTarget(sourceBytes);
    final dimensions = await operations.decode(bytes);
    final thumbnail = generateBlurredThumbnail
        ? await operations.generateThumbnail(bytes)
        : null;

    final normalizedExtension = extension.isEmpty
        ? '.jpg'
        : extension.startsWith('.')
        ? extension
        : '.$extension';
    final outputPath = path.join(
      await operations.documentDirectory(),
      '${operations.newId()}$normalizedExtension',
    );
    final lease = UncommittedAttachmentSourceLease(
      sourcePath: outputPath,
      cleanupSource: operations.cleanup,
    );

    try {
      // Keep every fallible transformation above this point so the filesystem
      // contains a temporary source for the shortest possible interval.
      await operations.write(outputPath, bytes);
      return PreparedImageAttachment(
        bytes: bytes,
        dimensions: dimensions,
        blurredThumbnail: thumbnail,
        sourceLease: lease,
      );
    } catch (_) {
      // The writer may have created a partial file before reporting failure.
      await lease.releaseByCaller();
      rethrow;
    }
  }

  Future<Uint8List> _compressToTarget(Uint8List sourceBytes) async {
    if (sourceBytes.length <= maxImageBytes) {
      return operations.compress(
        sourceBytes,
        quality: 90,
        minWidth: 1920,
        minHeight: 1920,
      );
    }

    var quality = 85;
    var minWidth = 1920;
    var minHeight = 1920;
    var compressed = sourceBytes;

    while (quality >= 50) {
      compressed = await operations.compress(
        sourceBytes,
        quality: quality,
        minWidth: minWidth,
        minHeight: minHeight,
      );
      if (compressed.length <= maxImageBytes) return compressed;
      quality -= 10;
    }

    quality = 70;
    while (minWidth >= 800) {
      compressed = await operations.compress(
        sourceBytes,
        quality: quality,
        minWidth: minWidth,
        minHeight: minHeight,
      );
      if (compressed.length <= maxImageBytes) return compressed;
      minWidth = (minWidth * 0.75).toInt();
      minHeight = (minHeight * 0.75).toInt();
    }

    return operations.compress(
      sourceBytes,
      quality: 50,
      minWidth: 800,
      minHeight: 800,
    );
  }
}
