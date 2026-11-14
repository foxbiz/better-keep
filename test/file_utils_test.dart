import 'package:better_keep/utils/file_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const container = '/var/mobile/Containers/Data/Application/current';
  const previous = '/var/mobile/Containers/Data/Application/previous';

  for (final scope in ['', '/firebase_emulator']) {
    final documents = '$container/Library/Application Support$scope';
    final cache = '$container/Library/Caches$scope';
    String repair(String value) =>
        FileUtils.rebaseIosPath(value, documentDir: documents, cacheDir: cache);

    test(
      'iOS $scope paths stay stable and rebase across container changes',
      () {
        expect(repair(documents), documents);
        expect(repair(cache), cache);
        for (final (marker, target) in [
          ('/Library/Application Support', documents),
          ('/Library/Caches', cache),
          ('/Documents', documents),
        ]) {
          for (final suffix in [
            'sketch.json',
            'external_sync_media/library/photo.png',
          ]) {
            final expected = '$target/$suffix';
            expect(repair('$container$marker$scope/$suffix'), expected);
            expect(repair('$previous$marker$scope/$suffix'), expected);
            expect(
              repair(expected),
              expected,
              reason: 'Repair must be idempotent',
            );
          }
        }
      },
    );

    test(
      'iOS $scope keeps legacy unscoped sources within the selected roots',
      () {
        expect(
          repair('$previous/Documents/sketch.json'),
          '$documents/sketch.json',
        );
        expect(
          repair('$previous/Library/Caches/audio.m4a'),
          '$cache/audio.m4a',
        );
        expect(
          repair('https://example.com/photo.png'),
          'https://example.com/photo.png',
        );
        expect(
          repair('/documents/firebase_emulator/photo.png'),
          '/documents/firebase_emulator/photo.png',
        );
      },
    );
  }
}
