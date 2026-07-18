import 'package:better_keep/components/e2ee_status_card.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'ready E2EE card gives the recovery tile a clipped Material surface',
    (tester) async {
      var manageRecoveryKeyCalled = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: E2EEStatusCard(
              status: E2EEStatus.ready,
              approvedDeviceCount: 2,
              hasRecoveryKey: true,
              onManageRecoveryKey: () {
                manageRecoveryKeyCalled = true;
              },
              onSetupE2ee: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('2 authorized'), findsOneWidget);

      final recoveryTile = find.byType(ListTile);
      expect(recoveryTile, findsOneWidget);
      expect(
        find.ancestor(
          of: recoveryTile,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Material &&
                widget.shape is RoundedRectangleBorder &&
                widget.clipBehavior == Clip.antiAlias,
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(recoveryTile);
      await tester.pump();

      expect(manageRecoveryKeyCalled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ready E2EE card localizes all user-facing details', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ja'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: E2EEStatusCard(
            status: E2EEStatus.ready,
            approvedDeviceCount: 2,
            hasRecoveryKey: false,
            onManageRecoveryKey: () {},
            onSetupE2ee: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('ノートは保護されています'), findsOneWidget);
    expect(find.text('ノートと添付ファイルは暗号化されています'), findsOneWidget);
    expect(find.text('暗号化'), findsOneWidget);
    expect(find.text('鍵交換'), findsOneWidget);
    expect(find.text('鍵サイズ'), findsOneWidget);
    expect(find.text('デバイス'), findsOneWidget);
    expect(find.text('2台承認済み'), findsOneWidget);
    expect(find.text('リカバリーキー'), findsOneWidget);
    expect(find.text('重要'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
