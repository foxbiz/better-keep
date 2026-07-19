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

  testWidgets('quarantined legacy sketch opens a non-editable recovery view', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    final sketch = SketchData(encryptedStrokes: 'existing-ciphertext')
      ..markLegacyMigrationFailed('conversion failed');
    final note = Note(
      locked: true,
      attachments: [NoteAttachment.sketch(sketch)],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SketchPage(note: note, sketch: sketch),
      ),
    );
    await tester.pump();

    expect(find.text('Protected sketch'), findsOneWidget);
    expect(find.textContaining('original encrypted drawing'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
