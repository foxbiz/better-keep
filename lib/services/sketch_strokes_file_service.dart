import 'dart:convert';
import 'dart:typed_data';

import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/utils/encryption.dart';
import 'package:better_keep/utils/logger.dart';

enum SketchStrokesLoadResult {
  alreadyLoaded,
  loaded,
  unavailable,
  empty,
  passwordProtected,
  legacyPasswordProtected,
  invalid;

  bool get hasStrokes =>
      this == SketchStrokesLoadResult.alreadyLoaded ||
      this == SketchStrokesLoadResult.loaded;

  /// The source was parsed successfully, including a verified empty drawing.
  bool get isHydrated => hasStrokes || this == SketchStrokesLoadResult.empty;
}

/// Loads the current file-backed sketch format into memory.
///
/// Password-protected files remain deferred unless an authenticated caller
/// supplies a decoder. Decoding is in-memory and never rewrites the canonical
/// source. [readBytes] and [pathExists] are injectable for deterministic tests.
class SketchStrokesFileService {
  SketchStrokesFileService._();

  static Future<SketchStrokesLoadResult> hydrate(
    SketchData sketch, {
    Future<Uint8List> Function(String path)? readBytes,
    Future<bool> Function(String path)? pathExists,
    Future<Uint8List> Function(Uint8List protectedBytes)?
    passwordProtectedDecoder,
  }) async {
    if (sketch.hasHydratedStrokeSource) {
      return sketch.strokes.isEmpty
          ? SketchStrokesLoadResult.empty
          : SketchStrokesLoadResult.alreadyLoaded;
    }

    if (sketch.strokes.isNotEmpty) {
      sketch.markStrokesHydrated();
      return SketchStrokesLoadResult.alreadyLoaded;
    }

    final strokesPath = sketch.strokesFilePath;
    if (strokesPath == null ||
        strokesPath.isEmpty ||
        strokesPath.startsWith('http')) {
      return SketchStrokesLoadResult.unavailable;
    }

    try {
      final exists = pathExists != null
          ? await pathExists(strokesPath)
          : await (await fileSystem()).exists(strokesPath);
      if (!exists) return SketchStrokesLoadResult.unavailable;

      var bytes = readBytes != null
          ? await readBytes(strokesPath)
          : await readEncryptedBytes(strokesPath);
      // ENCP is an expected state for a locked note downloaded on a new
      // device. An authenticated editor may decode it in memory without
      // changing the canonical protected file.
      if (isBytesPasswordEncrypted(bytes)) {
        if (passwordProtectedDecoder == null) {
          return SketchStrokesLoadResult.passwordProtected;
        }
        bytes = await passwordProtectedDecoder(bytes);
        if (bytes.isEmpty || isBytesPasswordEncrypted(bytes)) {
          return SketchStrokesLoadResult.invalid;
        }
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        return SketchStrokesLoadResult.invalid;
      }

      sketch.loadFromStrokesFileJson(decoded);
      if (sketch.hasEncryptedStrokes) {
        return SketchStrokesLoadResult.legacyPasswordProtected;
      }
      return sketch.strokes.isEmpty
          ? SketchStrokesLoadResult.empty
          : SketchStrokesLoadResult.loaded;
    } catch (e, stackTrace) {
      AppLogger.error(
        'Failed to hydrate sketch strokes from $strokesPath',
        e,
        stackTrace,
      );
      return SketchStrokesLoadResult.invalid;
    }
  }

  /// Hydrates every sketch whose password protection has already been removed.
  ///
  /// Failures remain isolated to their sketch so one corrupt attachment cannot
  /// prevent the rest of a successfully unlocked note from being repaired.
  static Future<Map<SketchData, SketchStrokesLoadResult>> hydrateDecrypted(
    Iterable<SketchData> sketches, {
    Future<SketchStrokesLoadResult> Function(SketchData sketch)? hydrateSketch,
  }) async {
    final results = <SketchData, SketchStrokesLoadResult>{};
    final load = hydrateSketch ?? hydrate;
    for (final sketch in sketches) {
      results[sketch] = await load(sketch);
    }
    return results;
  }
}
