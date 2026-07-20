import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS declares a meaningful when-in-use location purpose string', () {
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
    final match = RegExp(
      r'<key>NSLocationWhenInUseUsageDescription</key>\s*'
      r'<string>([^<]+)</string>',
    ).firstMatch(infoPlist);

    expect(match, isNotNull);
    expect(match!.group(1), contains('location metadata'));
    expect(match.group(1), contains('photos attached to notes'));
  });
}
