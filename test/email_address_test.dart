import 'package:better_keep/utils/email_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'email forms accept aliases and long domains but reject mistyped addresses',
    () {
      expect(isValidEmailAddress('reader+notes@example.technology'), isTrue);
      for (final address in [
        'reader',
        'reader@@example.com',
        'a@b..com',
        ' reader@example.com ',
      ]) {
        expect(isValidEmailAddress(address), isFalse, reason: address);
      }
    },
  );
}
