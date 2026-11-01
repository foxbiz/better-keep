import 'package:better_keep/components/user_devices_section.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final devices = List.generate(
    6,
    (index) => DeviceDocument(
      id: '$index',
      name: 'Device $index',
      platform: 'android',
      publicKey: 'public',
      status: DeviceStatus.approved,
      createdAt: DateTime.utc(2026),
    ),
  );

  Widget section({
    required bool showAll,
    required bool main,
    required VoidCallback open,
  }) => UserDevicesSection(
    devices: devices,
    showAll: showAll,
    isMainDevice: main,
    loading: false,
    error: null,
    onRefresh: () {},
    onShowAll: open,
    loadingBuilder: (_) => const SizedBox(),
    tileBuilder: (_, device, _) => Text(device.name),
  );

  testWidgets('compact list caps at three and Show more opens full list', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: betterKeepLocalizationDelegates,
        supportedLocales: betterKeepSupportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: section(
              showAll: false,
              main: false,
              open: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('All devices')),
                    body: section(showAll: true, main: false, open: () {}),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Device '), findsNWidgets(3));
    expect(find.text('Show more (3+)'), findsOneWidget);
    await tester.tap(find.text('Show more (3+)'));
    await tester.pumpAndSettle();
    expect(find.text('All devices'), findsOneWidget);
    expect(find.textContaining('Device '), findsNWidgets(6));
    expect(
      find.text('Only your main device can remove other devices.'),
      findsOneWidget,
    );
    expect(find.byType(Divider), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('main-device full list omits the removal restriction hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: betterKeepLocalizationDelegates,
        supportedLocales: betterKeepSupportedLocales,
        home: Scaffold(body: section(showAll: true, main: true, open: () {})),
      ),
    );
    expect(find.textContaining('Device '), findsNWidgets(6));
    expect(
      find.text('Only your main device can remove other devices.'),
      findsNothing,
    );
    expect(find.byType(TextButton), findsNothing);
  });
}
