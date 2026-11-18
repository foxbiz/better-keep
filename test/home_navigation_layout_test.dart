import 'package:better_keep/components/logo.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/home/home_layout.dart';
import 'package:better_keep/pages/home/sidebar.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('persistent navigation needs width and height, not landscape alone', () {
    for (final (size, expected) in [
      (const Size(852, 393), false),
      (const Size(1440, 450), false),
      (const Size(799, 900), false),
      (const Size(800, 639), false),
      (const Size(800, 640), true),
      (const Size(1024, 768), true),
      (const Size(1440, 900), true),
    ]) {
      expect(
        hasRoomForHomeSidebar(MediaQueryData(size: size)),
        expected,
        reason: '$size',
      );
    }
    const desktop = MediaQueryData(size: Size(1024, 768));
    expect(
      hasRoomForHomeSidebar(
        desktop.copyWith(textScaler: TextScaler.linear(1.5)),
      ),
      isFalse,
    );
    expect(
      hasRoomForHomeSidebar(
        desktop.copyWith(viewInsets: const EdgeInsets.only(bottom: 400)),
      ),
      isTrue,
      reason: 'Opening the keyboard must not move search to another layout',
    );
    expect(
      hasRoomForHomeSidebar(
        const MediaQueryData(
          size: Size(820, 620),
          viewPadding: EdgeInsets.fromLTRB(30, 24, 0, 0),
        ),
      ),
      isFalse,
    );
  });

  testWidgets('short wide drawer scrolls all actions and closes on selection', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AppState.showNotes = NoteType.all;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => AppState.showNotes = NoteType.all);
    final scaffoldKey = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          key: scaffoldKey,
          drawer: const Drawer(child: Sidebar()),
          body: const Text('Library'),
        ),
      ),
    );
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
    expect(find.byType(Logo), findsOneWidget);
    expect(tester.takeException(), isNull);
    final menu = find.descendant(
      of: find.byType(Sidebar),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('Upgrade to Pro'),
      140,
      scrollable: menu,
    );
    await tester.pumpAndSettle();
    expect(find.text('Upgrade to Pro').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Archive'),
      -140,
      scrollable: menu,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
    expect(AppState.showNotes, NoteType.archived);
    expect(find.text('Library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsed navigation keeps labeled targets and fades out text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: SizedBox(
            width: 80,
            child: Sidebar(persistent: true, shrink: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Logo), findsNothing);
    final labelFade = find.ancestor(
      of: find.text('Notes'),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(labelFade).opacity, 0);
    expect(find.byTooltip('Notes'), findsOneWidget);
    expect(find.byIcon(Icons.note).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
