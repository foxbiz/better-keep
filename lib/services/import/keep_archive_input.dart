import 'dart:async';
import 'dart:typed_data';

import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:better_keep/services/import/keep_import_source.dart';

abstract class KeepArchiveInput {
  const KeepArchiveInput();

  factory KeepArchiveInput.memory(Uint8List bytes) = _MemoryArchiveInput;

  factory KeepArchiveInput.stream(
    Stream<List<int>> stream, {
    required int size,
  }) = _StreamArchiveInput;

  factory KeepArchiveInput.file(String path, {required int size}) =
      _FileArchiveInput;

  int get size;

  Future<Uint8List> read({
    required int maxBytes,
    required KeepImportCancellationToken cancellationToken,
  });

  void validateSize(int maxBytes) {
    if (size < 0) {
      throw const KeepImportValidationException(
        'The selected ZIP does not report a valid size.',
      );
    }
    if (size > maxBytes) {
      throw KeepImportValidationException(
        'The ZIP is larger than the ${_formatBytes(maxBytes)} import limit.',
      );
    }
  }
}

class _MemoryArchiveInput extends KeepArchiveInput {
  const _MemoryArchiveInput(this.bytes);

  final Uint8List bytes;

  @override
  int get size => bytes.length;

  @override
  Future<Uint8List> read({
    required int maxBytes,
    required KeepImportCancellationToken cancellationToken,
  }) async {
    validateSize(maxBytes);
    cancellationToken.throwIfCancelled();
    return bytes;
  }
}

class _StreamArchiveInput extends KeepArchiveInput {
  const _StreamArchiveInput(this.stream, {required this.size});

  final Stream<List<int>> stream;

  @override
  final int size;

  @override
  Future<Uint8List> read({
    required int maxBytes,
    required KeepImportCancellationToken cancellationToken,
  }) async {
    validateSize(maxBytes);
    final bytes = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in stream) {
      cancellationToken.throwIfCancelled();
      received += chunk.length;
      if (received > maxBytes) {
        throw KeepImportValidationException(
          'The ZIP is larger than the ${_formatBytes(maxBytes)} import limit.',
        );
      }
      bytes.add(chunk);
    }
    cancellationToken.throwIfCancelled();
    return bytes.takeBytes();
  }
}

class _FileArchiveInput extends KeepArchiveInput {
  const _FileArchiveInput(this.path, {required this.size});

  final String path;

  @override
  final int size;

  @override
  Future<Uint8List> read({
    required int maxBytes,
    required KeepImportCancellationToken cancellationToken,
  }) async {
    validateSize(maxBytes);
    return readKeepArchiveFile(
      path,
      maxBytes: maxBytes,
      cancellationToken: cancellationToken,
    );
  }
}

String _formatBytes(int bytes) {
  final mebibytes = bytes / KeepImportOptions.mebibyte;
  return '${mebibytes.toStringAsFixed(mebibytes.roundToDouble() == mebibytes ? 0 : 1)} MB';
}
