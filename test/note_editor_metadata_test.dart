import 'dart:convert';

import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init(prefs: await SharedPreferences.getInstance());
  });

  testWidgets(
    'shows muted edited date and 12-hour time before ellipsized labels',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _host(
          Note(
            title: 'Travel plans',
            content: _content('Travel plans'),
            readOnly: true,
            updatedAt: DateTime(2026, 8, 16, 13, 45),
            labels:
                ' Work, Personal, A deliberately long label that cannot fit ',
          ),
          alwaysUse24HourFormat: false,
        ),
      );
      await tester.pump();

      final title = find.byType(TextField);
      final metadata = find.byKey(const ValueKey('note_editor_metadata'));
      final timestamp = find.byKey(
        const ValueKey('note_editor_metadata_timestamp'),
      );
      final labels = find.byKey(const ValueKey('note_editor_metadata_labels'));
      final metadataContext = tester.element(metadata);
      final updatedAt = DateTime(2026, 8, 16, 13, 45).toLocal();
      final expectedTimestamp =
          '${MaterialLocalizations.of(metadataContext).formatMediumDate(updatedAt)}, '
          '${TimeOfDay.fromDateTime(updatedAt).format(metadataContext)}';

      expect(metadata, findsOneWidget);
      expect(tester.widget<Text>(timestamp).data, expectedTimestamp);
      expect(expectedTimestamp, contains('1:45 PM'));
      expect(
        find.text('Work, Personal, A deliberately long label that cannot fit'),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(metadata).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
      );
      expect(
        tester.getTopLeft(timestamp).dx,
        lessThan(tester.getTopLeft(labels).dx),
      );

      final labelText = tester.widget<Text>(labels);
      expect(labelText.maxLines, 1);
      expect(labelText.overflow, TextOverflow.ellipsis);
      expect(
        tester.renderObject<RenderParagraph>(labels).didExceedMaxLines,
        isTrue,
      );
      expect(
        tester.widget<Text>(timestamp).style?.color,
        Colors.black.withValues(alpha: 0.55),
      );
    },
  );

  testWidgets('uses 24-hour time when requested', (tester) async {
    final updatedAt = DateTime(2026, 8, 16, 13, 45);
    await tester.pumpWidget(
      _host(
        Note(
          title: '24-hour time',
          content: _content('24-hour time'),
          readOnly: true,
          updatedAt: updatedAt,
        ),
        editorKey: '24-hour',
        alwaysUse24HourFormat: true,
      ),
    );
    await tester.pump();

    final metadata = find.byKey(const ValueKey('note_editor_metadata'));
    final timestamp = find.byKey(
      const ValueKey('note_editor_metadata_timestamp'),
    );
    final metadataContext = tester.element(metadata);
    final localUpdatedAt = updatedAt.toLocal();
    final expectedTimestamp =
        '${MaterialLocalizations.of(metadataContext).formatMediumDate(localUpdatedAt)}, '
        '${MaterialLocalizations.of(metadataContext).formatTimeOfDay(TimeOfDay.fromDateTime(localUpdatedAt), alwaysUse24HourFormat: true)}';

    expect(tester.widget<Text>(timestamp).data, expectedTimestamp);
    expect(expectedTimestamp, contains('13:45'));
  });

  testWidgets('shows each available value and hides empty metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Note(
          title: 'Timestamp only',
          content: _content('Timestamp only'),
          readOnly: true,
          updatedAt: DateTime(2026, 8, 16),
        ),
        editorKey: 'timestamp-only',
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('note_editor_metadata')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('note_editor_metadata_timestamp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('note_editor_metadata_labels')),
      findsNothing,
    );

    await tester.pumpWidget(
      _host(
        Note(
          title: 'Labels only',
          content: _content('Labels only'),
          readOnly: true,
          labels: ' Work, , Personal ',
        ),
        editorKey: 'labels-only',
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('note_editor_metadata')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('note_editor_metadata_timestamp')),
      findsNothing,
    );
    expect(find.text('Work, Personal'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        Note(
          title: 'No metadata',
          content: _content('No metadata'),
          readOnly: true,
          labels: ' , ',
        ),
        editorKey: 'empty',
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('note_editor_metadata')), findsNothing);
  });
}

Widget _host(
  Note note, {
  String editorKey = 'editor',
  bool? alwaysUse24HourFormat,
}) => MaterialApp(
  localizationsDelegates: betterKeepLocalizationDelegates,
  supportedLocales: betterKeepSupportedLocales,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(alwaysUse24HourFormat: alwaysUse24HourFormat),
      child: NoteEditor(key: ValueKey(editorKey), note: note),
    ),
  ),
);

String _content(String title) => jsonEncode([
  {'insert': title},
  {
    'insert': '\n',
    'attributes': {'header': 1},
  },
  {'insert': '\n'},
]);
