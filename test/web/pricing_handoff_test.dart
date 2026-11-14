@TestOn('browser')
library;

import 'package:better_keep/services/monetization/razorpay_web.dart';
import 'package:better_keep/services/monetization/subscription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('pricing link survives the wait for sign-in and is consumed once', () {
    final history = web.window.history;
    final original = web.window.location.href;
    final state = history.state;
    final service = SubscriptionService.instance;
    final previousCurrency = service.selectedCurrency.value;
    addTearDown(() {
      history.replaceState(state, '', original);
      service.selectedCurrency.value = previousCurrency;
    });

    for (final currency in RazorpayCurrency.values) {
      final url = web.URL(original);
      url.searchParams.set('upgrade', currency.code);
      url.searchParams.set('source', 'test');
      url.hash = '#notes';
      history.replaceState(state, '', url.href);

      expect(pricingLinkCurrency, currency.code);
      expect(web.window.location.href, url.href);
      expect(service.takePricingUpgrade(), isTrue);
      expect(service.selectedCurrency.value, currency);
      url.searchParams.delete('upgrade');
      expect(web.window.location.href, url.href);
      expect(service.takePricingUpgrade(), isFalse);
    }

    for (final query in ['upgrade=EUR', 'upgrade=USD&upgrade=INR']) {
      final url = web.URL(original)..search = query;
      history.replaceState(state, '', url.href);
      expect(service.takePricingUpgrade(), isFalse);
      expect(web.window.location.href, url.href);
    }
  });
}
