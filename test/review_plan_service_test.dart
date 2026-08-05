import 'package:better_keep/services/monetization/plan_service.dart';
import 'package:better_keep/services/monetization/user_plan.dart';
import 'package:better_keep/services/review_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PlanService.instance.dispose();
    SharedPreferences.setMockInitialValues({
      'subscription_cache': 'ordinary-account-cache',
    });
  });

  tearDown(() {
    PlanService.instance.dispose();
  });

  test('active signed review entitlement becomes Pro immediately', () async {
    final expiresAt = DateTime.utc(2100, 1, 1);
    final authorization = ReviewAuthorization.fromClaims(
      uid: 'review-uid',
      claims: {
        'plan': 'pro',
        'planExpiresAt': expiresAt.millisecondsSinceEpoch,
      },
    );

    PlanService.instance.activateReviewSession(authorization);

    expect(PlanService.instance.currentPlan, UserPlan.pro);
    expect(PlanService.instance.status.expiresAt, expiresAt);
    expect(PlanService.instance.status.purchasePlatform, 'review');
    expect(PlanService.instance.entitlements.hasUnlimitedLockedNotes, isTrue);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('subscription_cache'),
      'ordinary-account-cache',
    );
  });

  test('invalid or expired signed review entitlement becomes Free', () async {
    for (final claims in <Map<String, dynamic>>[
      const {'plan': 'pro'},
      const {'plan': 'PRO', 'planExpiresAt': 4102444800000},
      const {'plan': 'pro', 'planExpiresAt': '4102444800000'},
      {
        'plan': 'pro',
        'planExpiresAt': DateTime.utc(2000, 1, 1).millisecondsSinceEpoch,
      },
    ]) {
      PlanService.instance.activateReviewSession(
        ReviewAuthorization.fromClaims(uid: 'review-uid', claims: claims),
      );
      expect(
        PlanService.instance.currentPlan,
        UserPlan.free,
        reason: claims.toString(),
      );
    }

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('subscription_cache'),
      'ordinary-account-cache',
    );
  });
}
