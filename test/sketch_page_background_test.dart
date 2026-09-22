import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String imagePath;
  late List<String> recoveries;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sketch-background-');
    imagePath = '${directory.path}/image.png';
    await File(imagePath).writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
    SketchPage.clearBackgroundImageCache();
    UniversalImageCache.instance.clear();
    recoveries = [];
    SketchPage.backgroundRecoveryOverride = (path) async {
      recoveries.add(path);
      return null;
    };
  });

  tearDown(() async {
    SketchPage.backgroundPathResolverOverride = null;
    SketchPage.backgroundRecoveryOverride = null;
    SketchPage.clearBackgroundImageCache();
    UniversalImageCache.instance.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await directory.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, SketchData sketch, {Note? note}) =>
      tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SketchPage(note: note ?? Note(), sketch: sketch),
        ),
      );

  testWidgets('relocated iOS background loads locally without recovery', (
    tester,
  ) async {
    const oldPath = '/old-container/Library/Application Support/image.png';
    final sketch = SketchData(
      backgroundImage: oldPath,
      previewImage: imagePath,
    );
    // Simulate FileUtils.fixPath on this host; the page must use its result
    // for both the existence check and the authenticated attachment read.
    SketchPage.backgroundPathResolverOverride = (path) async {
      expect(path, oldPath);
      return imagePath;
    };

    await open(tester, sketch);
    await _pumpUntil(tester, () => sketch.backgroundImage == imagePath);

    expect(recoveries, isEmpty);
    expect(
      find.text('Background unavailable; drawing preserved'),
      findsNothing,
    );
  });

  testWidgets('initial opening recovers a missing background once', (
    tester,
  ) async {
    final missing = '${directory.path}/missing.png';
    final sketch = SketchData(
      backgroundImage: missing,
      previewImage: imagePath,
    );
    final response = Completer<String?>();
    SketchPage.backgroundRecoveryOverride = (path) {
      recoveries.add(path);
      return response.future;
    };

    await open(tester, sketch);
    await _pumpUntil(tester, () => recoveries.isNotEmpty);
    expect(find.byType(UniversalImage), findsNothing);
    response.complete(imagePath);
    await _pumpUntil(tester, () => sketch.backgroundImage == imagePath);

    expect(recoveries, [missing]);
    expect(find.byType(UniversalImage), findsOneWidget);
    expect(
      find.text('Background unavailable; drawing preserved'),
      findsNothing,
    );
  });

  testWidgets(
    'failed recovery preserves strokes and Retry uses the same loader',
    (tester) async {
      final missing = '${directory.path}/missing.png';
      final stroke = SketchStroke(
        points: '1,1,0.5;2,2,0.5;',
        color: Colors.black,
        size: 2,
      );
      final sketch = SketchData(
        backgroundImage: missing,
        previewImage: imagePath,
        strokes: [stroke],
      );
      await open(tester, sketch);
      await _pumpUntil(tester, () => find.text('Retry').evaluate().isNotEmpty);
      expect(recoveries, [missing]);
      expect(sketch.backgroundImage, missing);
      expect(sketch.strokes, [stroke]);

      SketchPage.backgroundRecoveryOverride = (path) async {
        recoveries.add(path);
        return imagePath;
      };
      await tester.tap(find.text('Retry'));
      await _pumpUntil(tester, () => sketch.backgroundImage == imagePath);

      expect(recoveries, [missing, missing]);
      expect(sketch.strokes, [stroke]);
      expect(
        find.text('Background unavailable; drawing preserved'),
        findsNothing,
      );
    },
  );

  testWidgets('Back closes a clean sketch without waiting for recovery', (
    tester,
  ) async {
    final missing = '${directory.path}/missing.png';
    final sketch = SketchData(
      backgroundImage: missing,
      previewImage: imagePath,
    );
    final response = Completer<String?>();
    var recoveryStarted = false;
    SketchPage.backgroundRecoveryOverride = (_) {
      recoveryStarted = true;
      return response.future;
    };
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SizedBox.shrink(),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => SketchPage(note: Note(), sketch: sketch),
        ),
      ),
    );
    await tester.pumpAndSettle();
    try {
      await _pumpUntil(tester, () => recoveryStarted);
      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(SketchPage), findsNothing);
    } finally {
      response.complete(imagePath);
    }
    await tester.pumpAndSettle();
    expect(sketch.backgroundImage, missing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing sketch during recovery ignores its late result', (
    tester,
  ) async {
    final missing = '${directory.path}/missing.png';
    final sketch = SketchData(
      backgroundImage: missing,
      previewImage: imagePath,
    );
    final response = Completer<String?>();
    SketchPage.backgroundRecoveryOverride = (path) {
      recoveries.add(path);
      return response.future;
    };

    final nextSketch = SketchData();
    await open(
      tester,
      sketch,
      note: Note(
        attachments: [
          NoteAttachment.sketch(sketch),
          NoteAttachment.sketch(nextSketch),
        ],
      ),
    );
    await _pumpUntil(tester, () => recoveries.isNotEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2'));
    await tester.pumpAndSettle();
    response.complete(imagePath);
    await tester.pumpAndSettle();

    expect(find.byType(SketchPage), findsOneWidget);
    expect(find.text('2/2'), findsOneWidget);
    expect(sketch.backgroundImage, missing);
    expect(nextSketch.backgroundImage, isNull);
    expect(find.byType(UniversalImage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (ready()) return;
  }
  fail('Sketch background loading did not reach the expected state');
}
