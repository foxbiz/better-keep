import 'package:better_keep/services/monetization/purchase_feedback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes Google Play already-owned error variants', () {
    expect(isAlreadyOwnedStoreError('ITEM_ALREADY_OWNED'), isTrue);
    expect(
      isAlreadyOwnedStoreError('BillingResponse.itemAlreadyOwned'),
      isTrue,
    );
    expect(isAlreadyOwnedStoreError('This item is already purchased'), isTrue);
  });

  test('does not classify unrelated launch failures as already owned', () {
    expect(isAlreadyOwnedStoreError('SERVICE_UNAVAILABLE'), isFalse);
    expect(isAlreadyOwnedStoreError(null), isFalse);
  });
}
