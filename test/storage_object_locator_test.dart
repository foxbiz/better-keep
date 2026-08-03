import 'package:better_keep/services/storage_object_locator.dart';
import 'package:flutter_test/flutter_test.dart';

const _bucket = 'better-keep-notes.firebasestorage.app';
const _path = 'users/user-1/notes/42/photo one.jpg';

void main() {
  group('StorageObjectLocator', () {
    test(
      'parses Firebase production download URLs without retaining tokens',
      () {
        final locator = StorageObjectLocator.parse(
          'https://firebasestorage.googleapis.com/v0/b/$_bucket/o/'
          'users%2Fuser-1%2Fnotes%2F42%2Fphoto%20one.jpg'
          '?alt=media&token=secret-token',
          configuredBucket: _bucket,
          emulatorMode: false,
        );

        expect(locator.bucket, _bucket);
        expect(locator.fullPath, _path);
        expect(locator.kind, StorageObjectLocatorKind.firebaseDownload);
        expect(locator.diagnosticDescription, isNot(contains('secret-token')));
      },
    );

    test('rebinds any emulator REST origin to its object address', () {
      for (final host in [
        'localhost',
        '10.0.2.2',
        '192.168.0.107',
        'unreachable.invalid',
      ]) {
        final locator = StorageObjectLocator.parse(
          'http://$host:9199/v0/b/$_bucket/o/'
          'users%2Fuser-1%2Fnotes%2F42%2Fphoto%20one.jpg?alt=media',
          configuredBucket: _bucket,
          emulatorMode: true,
        );
        expect(locator.fullPath, _path);
        expect(locator.kind, StorageObjectLocatorKind.emulatorDownload);
      }
    });

    test('supports gs and official GCS locators', () {
      final gs = StorageObjectLocator.parse(
        'gs://$_bucket/$_path',
        configuredBucket: _bucket,
        emulatorMode: false,
      );
      final gcs = StorageObjectLocator.parse(
        'https://storage.googleapis.com/$_bucket/$_path',
        configuredBucket: _bucket,
        emulatorMode: false,
      );
      expect(gs.fullPath, _path);
      expect(gcs.fullPath, _path);
    });

    test('rejects arbitrary production hosts and foreign buckets', () {
      expect(
        () => StorageObjectLocator.parse(
          'https://example.com/v0/b/$_bucket/o/file.bin',
          configuredBucket: _bucket,
          emulatorMode: false,
        ),
        throwsA(
          isA<StorageObjectLocatorException>().having(
            (error) => error.code,
            'code',
            'unsupported-production-host',
          ),
        ),
      );
      expect(
        () => StorageObjectLocator.parse(
          'gs://other-bucket/file.bin',
          configuredBucket: _bucket,
          emulatorMode: false,
        ),
        throwsA(
          isA<StorageObjectLocatorException>().having(
            (error) => error.code,
            'code',
            'bucket-mismatch',
          ),
        ),
      );
    });

    test('rejects malformed object locators before the Storage SDK', () {
      for (final value in [
        '',
        'file:///tmp/photo.jpg',
        'https://example.com',
      ]) {
        expect(
          () => StorageObjectLocator.parse(
            value,
            configuredBucket: _bucket,
            emulatorMode: true,
          ),
          throwsA(isA<StorageObjectLocatorException>()),
        );
      }
    });
  });
}
