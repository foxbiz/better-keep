import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/services/image_attachment_preparation_service.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Imports one image share as one note, owning copies of every attachment.
class SharedImageNoteService {
  static const maxSourceBytes = 50 * 1024 * 1024;
  static const maxSourcePixels = 24 * 1000 * 1000;

  final ImageAttachmentPreparationService preparation;
  final ImageAttachmentDecode inspectDimensions;
  final Future<int> Function(Note) saveNote;
  final Future<String> Function() sharedFileLabel;

  SharedImageNoteService({
    ImageAttachmentPreparationService? preparation,
    ImageAttachmentDecode? inspectDimensions,
    Future<int> Function(Note)? saveNote,
    Future<String> Function()? sharedFileLabel,
  }) : preparation =
           preparation ?? ImageAttachmentPreparationService.platform(),
       inspectDimensions = inspectDimensions ?? _inspectDimensions,
       saveNote = saveNote ?? ((note) => note.save()),
       sharedFileLabel = sharedFileLabel ?? _sharedFileLabel;

  static Future<String> _sharedFileLabel() async =>
      (await Label.getOrCreateSystemLabel(Label.sharedFileLabelName)).name;

  static bool isImage(SharedMediaFile file) {
    // A text selection that happens to end in .jpg is still text.
    if (file.type == SharedMediaType.text ||
        file.type == SharedMediaType.url ||
        file.type == SharedMediaType.video) {
      return false;
    }
    if (file.type == SharedMediaType.image ||
        (file.mimeType?.toLowerCase().startsWith('image/') ?? false)) {
      return true;
    }
    return RegExp(
      r'\.(jpe?g|png|gif|webp|bmp|heic|heif|avif)$',
      caseSensitive: false,
    ).hasMatch(file.path);
  }

  static Future<ImageAttachmentDimensions> _inspectDimensions(
    Uint8List bytes,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      return ImageAttachmentDimensions(
        width: descriptor.width,
        height: descriptor.height,
      );
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<Uint8List> _readSource(File source) async {
    final handle = await source.open();
    try {
      final length = await handle.length();
      if (length > maxSourceBytes) {
        throw const FormatException('Image exceeds 50 MB');
      }
      // Bound the read as well as the length check if the sender changes the file.
      final bytes = await handle.read(length + 1);
      if (bytes.length > maxSourceBytes) {
        throw const FormatException('Image exceeds 50 MB');
      }
      if (bytes.length > length) {
        throw const FormatException('Image changed while reading');
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  Future<Note> create(List<SharedMediaFile> images, {String? shareId}) async {
    if (images.isEmpty) throw ArgumentError.value(images, 'images');
    // Android's sharing plugin caches by display name. Collisions have already
    // overwritten the source by delivery, so importing would save wrong images.
    if (images.map((image) => image.path).toSet().length != images.length) {
      throw const SharedImagePathCollision();
    }
    // Keep cleanup ownership, not every compressed image's bytes, until save.
    final leases = <UncommittedAttachmentSourceLease>[];
    try {
      final note = Note(
        syncId: shareId,
        content: jsonEncode([
          {'insert': '\n'},
        ]),
      );
      for (final image in images) {
        late PreparedImageAttachment attachment;
        try {
          final uri = Uri.tryParse(image.path);
          final source = uri?.scheme == 'file'
              ? File.fromUri(uri!)
              : File(image.path);
          final bytes = await _readSource(source);
          final dimensions = await inspectDimensions(bytes);
          if (dimensions.width <= 0 ||
              dimensions.height <= 0 ||
              dimensions.width * dimensions.height > maxSourcePixels) {
            throw const FormatException('Image exceeds the 24 megapixel limit');
          }
          attachment = await preparation.prepare(
            sourceBytes: bytes,
            extension: '.jpg',
            generateBlurredThumbnail: false,
          );
        } catch (error) {
          throw SharedImageImportException(image.path, error);
        }
        leases.add(attachment.sourceLease);
        note.addImageDirectly(
          NoteImage(
            src: attachment.path,
            size: attachment.byteLength,
            index: note.images.length,
            aspectRatio:
                '${attachment.dimensions.width}:${attachment.dimensions.height}',
            lastModified: DateTime.now().toIso8601String(),
          ),
        );
      }
      note.labels = await sharedFileLabel();
      if (await saveNote(note) < 0) {
        throw StateError('Failed to save shared image note');
      }
      for (final lease in leases) {
        lease.markCommitted();
      }
      return note;
    } finally {
      // Failed batches leave neither a partial note nor orphaned image copies.
      // Never remove the sending app's source files.
      for (final lease in leases) {
        await lease.releaseByCaller();
      }
    }
  }
}

class SharedImageImportException implements Exception {
  final String path;
  final Object cause;

  const SharedImageImportException(this.path, this.cause);

  String get fileName => Uri.tryParse(path)?.pathSegments.lastOrNull ?? path;

  @override
  String toString() => 'Could not import $fileName: $cause';
}

class SharedImagePathCollision extends FormatException {
  const SharedImagePathCollision()
    : super('Shared images use the same source path');
}
