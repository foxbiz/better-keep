import 'package:better_keep/services/monetization/razorpay_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('rejects Android before creating a Razorpay subscription', () async {
    final service = RazorpayService.instance;

    expect(service.isAvailable, isFalse);

    final result = await service.purchaseSubscription(yearly: true);

    expect(result.success, isFalse);
    expect(result.error, 'Razorpay is not available on this platform');
  });
}
