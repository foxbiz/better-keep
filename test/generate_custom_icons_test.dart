import 'package:flutter_test/flutter_test.dart';

import '../scripts/generate_custom_icons.dart';

void main() {
  test('parses both quote styles and groups aliases by code point', () {
    final icons = parseCssIcons(r'''
.icon-loop:before { content: '\e90b'; }
.icon-repeat:before { content: "\e90b"; }
.icon-user:before { content: "\e90c"; }
''');

    expect(icons, hasLength(2));
    expect(icons.first.primaryName, 'loop');
    expect(icons.first.codePoint, 0xe90b);
    expect(icons.first.aliases, ['repeat']);
    expect(icons.last.primaryName, 'user');
    expect(icons.last.codePoint, 0xe90c);
    expect(generateDartFile(icons), contains('IconData(0xe90b,'));
  });

  test('rejects mismatched quotes and refuses empty generation', () {
    expect(
      parseCssIcons(r''' .icon-loop:before { content: '\e90b"; } '''),
      isEmpty,
    );
    expect(() => generateDartFile([]), throwsStateError);
  });
}
