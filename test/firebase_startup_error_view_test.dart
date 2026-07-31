import 'package:better_keep/components/firebase_startup_error_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('retryable startup failure invokes retry', (tester) async {
    var retryCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: FirebaseStartupErrorView(
          error: 'Review authorization unavailable',
          onRetry: () {
            retryCount++;
          },
        ),
      ),
    );

    expect(find.text('Review authorization unavailable'), findsOneWidget);
    expect(
      find.textContaining('local data has not been changed'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    expect(retryCount, 1);
  });

  testWidgets('routing failure requires restart and omits retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: FirebaseStartupErrorView(error: 'Partial emulator routing'),
      ),
    );

    expect(find.text('Partial emulator routing'), findsOneWidget);
    expect(find.textContaining('Restart the app'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
