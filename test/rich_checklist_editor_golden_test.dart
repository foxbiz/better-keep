import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/rich_checklist.dart';
import 'package:better_keep/pages/checklist_editor/rich_checklist_editor.dart';
import 'package:better_keep/services/checklist_delta_codec.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scenario in <(String, Color)>[
    ('light', const Color(0xfffff8e1)),
    ('dark', const Color(0xff202124)),
  ]) {
    testWidgets('focused checklist ${scenario.$1} rich-text surface', (
      tester,
    ) async {
      await _setGoldenSurface(tester);
      await tester.pumpWidget(
        _goldenHost(
          RichChecklistEditor(
            note: Note(readOnly: true, color: scenario.$2),
            session: _session('Launch checklist', _goldenDocument),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await expectLater(
        find.byKey(const ValueKey('golden_surface')),
        matchesGoldenFile('goldens/rich_checklist_${scenario.$1}.png'),
      );
    });
  }

  testWidgets('focused checklist drag proxy', (tester) async {
    await _setGoldenSurface(tester);
    await tester.pumpWidget(
      _goldenHost(
        RichChecklistEditor(
          note: Note(color: const Color(0xfffff8e1)),
          session: _session('Launch checklist', _goldenDocument),
        ),
      ),
    );
    await tester.pump();

    final dragHandle = find.descendant(
      of: find.byKey(const ValueKey('checklist-item-rtl')),
      matching: find.byIcon(Icons.drag_indicator),
    );
    final gesture = await tester.startGesture(tester.getCenter(dragHandle));
    await tester.pump();
    await gesture.moveBy(const Offset(120, 90));
    await tester.pump(const Duration(milliseconds: 200));

    await expectLater(
      find.byKey(const ValueKey('golden_surface')),
      matchesGoldenFile('goldens/rich_checklist_drag_proxy.png'),
    );
    await gesture.up();
  });

  testWidgets('focused checklist persistent caret states', (tester) async {
    await _setGoldenSurface(tester);
    await tester.pumpWidget(
      _goldenHost(
        RichChecklistEditor(
          note: Note(color: const Color(0xfffff8e1)),
          session: _session('Caret lifecycle', _goldenDocument),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Large and linked text', findRichText: true));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('golden_surface')),
      matchesGoldenFile('goldens/rich_checklist_new_row_caret.png'),
    );

    await tester.tap(
      find.text('مهمة متداخلة بألوان وأحجام مختلفة', findRichText: true),
    );
    await tester.pump();
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('golden_surface')),
      matchesGoldenFile('goldens/rich_checklist_switched_row_caret.png'),
    );
  });
}

ChecklistBlockEditSession _session(
  String title,
  RichChecklistDocument document,
) {
  final codec = ChecklistDeltaCodec();
  final body = codec.encodeBody(document);
  final block = codec
      .findChecklistBlockAt(documentFromJsonSafe(body), 0)
      .slice!
      .copyWith(document: document);
  return ChecklistBlockEditSession(
    title: title,
    bodyDelta: body,
    block: block,
    selectionStart: 0,
    selectionEnd: 0,
  );
}

RichChecklistDocument get _goldenDocument => RichChecklistDocument([
  RichChecklistItem(
    id: 'mixed',
    inlineDelta: const [
      {
        'insert': 'Large',
        'attributes': {'bold': true, 'size': '26', 'color': '#d93025'},
      },
      {'insert': ' and '},
      {
        'insert': 'linked text',
        'attributes': {
          'link': 'https://example.com',
          'underline': true,
          'color': '#188038',
        },
      },
    ],
    checked: false,
    indent: 0,
  ),
  RichChecklistItem(
    id: 'rtl',
    inlineDelta: const [
      {
        'insert': 'مهمة متداخلة بألوان وأحجام مختلفة',
        'attributes': {
          'italic': true,
          'size': '20',
          'background': '#fdd663',
          'color': '#1a73e8',
        },
      },
    ],
    checked: false,
    indent: 1,
    lineAttributes: const {
      'direction': 'rtl',
      'align': 'right',
      'line-height': 1.4,
    },
  ),
  RichChecklistItem(
    id: 'done',
    inlineDelta: const [
      {
        'insert': 'Completed task keeps its saved purple strike',
        'attributes': {'strike': true, 'color': '#9334e6'},
      },
    ],
    checked: true,
    indent: 0,
  ),
]);

Future<void> _setGoldenSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _goldenHost(Widget home) => RepaintBoundary(
  key: const ValueKey('golden_surface'),
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    localizationsDelegates: betterKeepLocalizationDelegates,
    supportedLocales: betterKeepSupportedLocales,
    theme: ThemeData.light(useMaterial3: true),
    home: home,
  ),
);
