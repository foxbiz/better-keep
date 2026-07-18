import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/settings/settings.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('motion preference defaults off, persists, and notifies', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await AppState.init(prefs: prefs);

    expect(AppState.followSystemAnimations, isFalse);

    bool? observedValue;
    void listener(dynamic value) => observedValue = value as bool;
    AppState.subscribe('follow_system_animations', listener);
    addTearDown(
      () => AppState.unsubscribe('follow_system_animations', listener),
    );

    AppState.followSystemAnimations = true;
    await pumpEventQueue();

    expect(observedValue, isTrue);
    expect(prefs.getBool('follow_system_animations'), isTrue);

    await AppState.init(prefs: prefs);
    expect(AppState.followSystemAnimations, isTrue);

    AppState.followSystemAnimations = false;
    await pumpEventQueue();
    expect(observedValue, isFalse);
    expect(prefs.getBool('follow_system_animations'), isFalse);

    await AppState.init(prefs: prefs);
    expect(AppState.followSystemAnimations, isFalse);
  });

  testWidgets('Settings exposes a localized opt-in switch', (tester) async {
    var value = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return SystemAnimationPreferenceTile(
                value: value,
                onChanged: (newValue) {
                  setState(() => value = newValue);
                },
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Follow system animation preference'), findsOneWidget);
    expect(
      find.text(
        'Reduce animations when enabled in your device or browser settings',
      ),
      findsOneWidget,
    );

    final switchFinder = find.widgetWithText(
      SwitchListTile,
      'Follow system animation preference',
    );
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    await tester.tap(switchFinder);
    await tester.pump();

    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
    expect(value, isTrue);
  });
}
