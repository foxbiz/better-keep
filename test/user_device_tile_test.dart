import 'package:better_keep/components/user_device_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('optional trailing widget can be omitted', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserDeviceTile(
            name: 'Current phone',
            subtitle: 'Android 16',
            platformIcon: Icons.android,
            isPending: false,
            isCurrentDevice: true,
            currentDeviceLabel: 'This device',
          ),
        ),
      ),
    );

    expect(find.text('Current phone'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long device name stays clear of approval actions', (
    tester,
  ) async {
    const deviceName =
        'A device name that is intentionally much too long for the card';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: UserDeviceTile(
                name: deviceName,
                subtitle: 'Android 16',
                platformIcon: Icons.android,
                isPending: true,
                isCurrentDevice: false,
                currentDeviceLabel: 'This device',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(onPressed: null, icon: Icon(Icons.check_circle)),
                    IconButton(onPressed: null, icon: Icon(Icons.cancel)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);

    final nameText = tester.widget<Text>(find.text(deviceName));
    expect(nameText.maxLines, 1);
    expect(nameText.overflow, TextOverflow.ellipsis);

    final nameBounds = tester.getRect(find.text(deviceName));
    final approveBounds = tester.getRect(
      find.widgetWithIcon(IconButton, Icons.check_circle),
    );
    expect(nameBounds.right, lessThanOrEqualTo(approveBounds.left));
  });
}
