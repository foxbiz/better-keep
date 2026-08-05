import 'package:firebase_storage/firebase_storage.dart';

enum StorageObjectLocatorKind {
  googleStorage,
  firebaseDownload,
  emulatorDownload,
}

class StorageObjectLocatorException implements Exception {
  const StorageObjectLocatorException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'StorageObjectLocatorException($code): $message';
}

/// A validated Storage object address with transport-specific URL details
/// removed.
class StorageObjectLocator {
  const StorageObjectLocator({
    required this.bucket,
    required this.fullPath,
    required this.kind,
    this.sourceHost,
  });

  final String bucket;
  final String fullPath;
  final StorageObjectLocatorKind kind;
  final String? sourceHost;

  static const _officialFirebaseHost = 'firebasestorage.googleapis.com';
  static const _officialGoogleHosts = {
    'storage.googleapis.com',
    'storage.cloud.google.com',
  };

  static StorageObjectLocator parse(
    String value, {
    required String configuredBucket,
    required bool emulatorMode,
  }) {
    final raw = value.trim();
    if (raw.isEmpty) {
      throw const StorageObjectLocatorException(
        'empty-locator',
        'Storage locator is empty',
      );
    }

    final locator = raw.startsWith('gs://')
        ? _parseGoogleStorage(raw)
        : _parseHttp(raw, emulatorMode: emulatorMode);
    if (locator.bucket != configuredBucket) {
      throw StorageObjectLocatorException(
        'bucket-mismatch',
        'Expected bucket $configuredBucket but found ${locator.bucket}',
      );
    }
    return locator;
  }

  static StorageObjectLocator _parseGoogleStorage(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        uri.scheme != 'gs' ||
        uri.host.isEmpty ||
        uri.pathSegments.isEmpty) {
      throw const StorageObjectLocatorException(
        'invalid-gs-url',
        'Invalid Google Storage object URL',
      );
    }
    return StorageObjectLocator(
      bucket: uri.host,
      fullPath: uri.pathSegments.join('/'),
      kind: StorageObjectLocatorKind.googleStorage,
      sourceHost: uri.host,
    );
  }

  static StorageObjectLocator _parseHttp(
    String raw, {
    required bool emulatorMode,
  }) {
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw const StorageObjectLocatorException(
        'invalid-http-url',
        'Invalid Storage HTTP URL',
      );
    }

    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments;
    if (segments.length >= 5 &&
        segments[0].startsWith('v') &&
        segments[1] == 'b' &&
        segments[3] == 'o') {
      if (!emulatorMode && host != _officialFirebaseHost) {
        throw const StorageObjectLocatorException(
          'unsupported-production-host',
          'Production Storage URLs must use an official Firebase host',
        );
      }
      final fullPath = segments.sublist(4).join('/');
      if (segments[2].isEmpty || fullPath.isEmpty) {
        throw const StorageObjectLocatorException(
          'missing-object-path',
          'Storage URL does not identify an object',
        );
      }
      return StorageObjectLocator(
        bucket: segments[2],
        fullPath: fullPath,
        kind: emulatorMode
            ? StorageObjectLocatorKind.emulatorDownload
            : StorageObjectLocatorKind.firebaseDownload,
        sourceHost: uri.host,
      );
    }

    if (_officialGoogleHosts.contains(host) && segments.length >= 2) {
      return StorageObjectLocator(
        bucket: segments.first,
        fullPath: segments.sublist(1).join('/'),
        kind: StorageObjectLocatorKind.googleStorage,
        sourceHost: uri.host,
      );
    }

    throw const StorageObjectLocatorException(
      'unsupported-url',
      'URL is not a supported Firebase Storage object locator',
    );
  }

  Reference resolve(FirebaseStorage storage) => storage.ref(fullPath);

  /// Safe for diagnostics: download tokens and other query parameters were
  /// discarded during parsing.
  String get diagnosticDescription =>
      'kind=${kind.name} host=${sourceHost ?? '-'} '
      'bucket=$bucket path=$fullPath';
}
