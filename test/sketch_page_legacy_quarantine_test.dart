import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });

  testWidgets('quarantined legacy sketch opens a localized recovery view', (
    tester,
  ) async {
    final sketch = SketchData(encryptedStrokes: 'existing-ciphertext')
      ..markLegacyMigrationFailed('conversion failed');
    final note = Note(
      locked: true,
      attachments: [NoteAttachment.sketch(sketch)],
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SketchPage(note: note, sketch: sketch),
      ),
    );
    await tester.pump();

    expect(find.text('Protected sketch'), findsOneWidget);
    expect(find.textContaining('original encrypted drawing'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('protected sketch recovery view honors the selected locale', (
    tester,
  ) async {
    final sketch = SketchData(encryptedStrokes: 'existing-ciphertext')
      ..markLegacyMigrationFailed('conversion failed');
    final note = Note(
      locked: true,
      attachments: [NoteAttachment.sketch(sketch)],
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ja'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SketchPage(note: note, sketch: sketch),
      ),
    );
    await tester.pump();

    expect(find.text('保護されたスケッチ'), findsOneWidget);
    expect(find.textContaining('元の暗号化された描画'), findsOneWidget);
    expect(find.text('Protected sketch'), findsNothing);
  });

  testWidgets('missing-background recovery controls are localized', (
    tester,
  ) async {
    final sketch = SketchData(
      backgroundImage: '/definitely-missing-sketch-background.png',
      aspectRatio: 1,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ja'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SketchPage(note: Note(), sketch: sketch),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();

    expect(find.text('背景を利用できません。描画は保持されています'), findsOneWidget);
    expect(find.text('再試行'), findsOneWidget);
    expect(
      find.text('Background unavailable; drawing preserved'),
      findsNothing,
    );
  });
}
