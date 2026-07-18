import 'package:better_keep/components/auth_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('AuthScaffold renders content and package version', (
    WidgetTester tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Better Keep',
      packageName: 'io.foxbiz.better_keep',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: AuthScaffold(showLogo: false, child: Text('Ready')),
      ),
    );
    await tester.pump();

    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('v1.2.3'), findsOneWidget);
  });
}
