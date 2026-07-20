import 'package:better_keep/components/note_card.dart';
import 'package:better_keep/components/note_image_grid.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppState.init();
  });

  group('locked note-card attachment privacy', () {
    test('body cache follows lock changes even when content is unchanged', () {
      final document = Document.fromJson([
        {'insert': 'Body becomes visible\n'},
      ]);
      final cache = NoteCardBodyCache();

      cache.update(locked: true, document: document);
      expect(cache.controller, isNull);

      cache.update(locked: false, document: document);
      expect(cache.controller, isNotNull);
      expect(
        cache.controller!.document.toPlainText(),
        'Body becomes visible\n',
      );

      cache.update(locked: true, document: document);
      expect(cache.controller, isNull);

      cache.dispose();
    });

    test('does not reveal attachments when a locked note is unlocked', () {
      expect(
        NoteCard.usesPrivateAttachmentPresentation(
          locked: true,
          unlocked: false,
        ),
        isTrue,
      );
      expect(
        NoteCard.usesPrivateAttachmentPresentation(
          locked: true,
          unlocked: true,
        ),
        isTrue,
      );
      expect(
        NoteCard.usesPrivateAttachmentPresentation(
          locked: false,
          unlocked: false,
        ),
        isFalse,
      );
    });

    test('private presentations contain thumbnails but no full paths', () {
      const imageThumbnail = 'image-thumbnail';
      const sketchThumbnail = 'sketch-thumbnail';
      final note = Note(
        id: 42,
        locked: true,
        attachments: [
          NoteAttachment.image(
            NoteImage(
              src: '/private/full-image.jpg',
              size: 1024,
              index: 0,
              aspectRatio: '4:3',
              lastModified: '2026-07-19T00:00:00Z',
              blurredThumbnail: imageThumbnail,
            ),
          ),
          NoteAttachment.sketch(
            SketchData(
              previewImage: '/private/full-sketch-preview.png',
              aspectRatio: 0.5,
              blurredThumbnail: sketchThumbnail,
            ),
          ),
          NoteAttachment.sketch(SketchData(aspectRatio: 1)),
        ],
      );

      final presentations = NoteCard.privateAttachmentPresentations(note);

      expect(presentations, hasLength(3));
      expect(presentations.map((image) => image.src), everyElement(isEmpty));
      expect(presentations.map((image) => image.blurredThumbnail), [
        imageThumbnail,
        sketchThumbnail,
        null,
      ]);
      expect(presentations.map((image) => image.ratio), [4 / 3, 0.5, 1]);
    });

    test('locked audio hides its label even while the PIN is cached', () {
      expect(
        NoteCard.showsRecordingTitle(locked: true, unlocked: false),
        isFalse,
      );
      expect(
        NoteCard.showsRecordingTitle(locked: true, unlocked: true),
        isFalse,
      );
      expect(
        NoteCard.showsRecordingTitle(locked: false, unlocked: false),
        isTrue,
      );

      final note = Note(
        title: 'Visible note title',
        locked: true,
        attachments: [
          NoteAttachment.audio(
            NoteRecording(
              src: '/private/audio.wav',
              title: 'Private recording title',
              transcript: 'Private transcript',
            ),
          ),
        ],
      );
      expect(note.title, 'Visible note title');
    });
  });

  testWidgets('locked audio card aggregates recordings into one count badge', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NoteCardAudioGroup(
            recordings: [
              NoteRecording(
                src: '/private/one.wav',
                title: 'Private recording one',
              ),
              NoteRecording(
                src: '/private/two.wav',
                title: 'Private recording two',
              ),
            ],
            locked: true,
            foregroundColor: Colors.black,
          ),
        ),
      ),
    );

    expect(find.text('Private recording one'), findsNothing);
    expect(find.text('Private recording two'), findsNothing);
    expect(find.text('2 audios'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
  });

  testWidgets('locked audio card uses the singular count label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: NoteCardAudioGroup(
            recordings: [NoteRecording(src: '/private/one.wav')],
            locked: true,
            foregroundColor: Colors.black,
          ),
        ),
      ),
    );

    expect(find.text('1 audio'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
  });

  testWidgets('unlocked audio card indicator retains its title', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: NoteCardAudioIndicator(
            recordingTitle: 'Recording title',
            locked: false,
            foregroundColor: Colors.black,
          ),
        ),
      ),
    );

    expect(find.text('Recording title'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
  });

  testWidgets('missing attachment preview uses a neutral placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          child: NoteImageGrid(
            images: [
              NoteImage(
                src: '',
                size: 0,
                index: 0,
                aspectRatio: '1:1',
                lastModified: '',
              ),
              NoteImage(
                src: '',
                size: 0,
                index: 1,
                aspectRatio: '1:1',
                lastModified: '',
              ),
            ],
            onImageTap: (_) {},
            noteId: 42,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.image_outlined), findsNWidgets(2));
    expect(find.byIcon(Icons.error), findsNothing);
    expect(find.byType(Hero), findsNothing);
  });

  group('reminder card actions', () {
    Note reminderNote({bool completed = false}) => Note(
      id: 42,
      title: 'Reminder action layout',
      completed: completed,
      reminder: Reminder(
        dateTime: DateTime.now().add(const Duration(days: 1)),
        type: ReminderType.notification,
      ),
    );

    Future<void> pumpCard(
      WidgetTester tester, {
      required double width,
      bool completed = false,
    }) async {
      AppState.showNotes = NoteType.reminder;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: NoteCard(
                  note: reminderNote(completed: completed),
                  index: 0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      addTearDown(() => AppState.showNotes = NoteType.all);
    }

    testWidgets('wide cards show localized actions on one row', (tester) async {
      await pumpCard(tester, width: 320);

      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(
        tester.getCenter(find.byIcon(Icons.done)).dy,
        tester.getCenter(find.byIcon(Icons.notifications_off_outlined)).dy,
      );
    });

    testWidgets('narrow cards use accessible icon-only actions on one row', (
      tester,
    ) async {
      await pumpCard(tester, width: 150);

      expect(find.text('Done'), findsNothing);
      expect(find.text('Remove'), findsNothing);
      expect(find.byTooltip('Done'), findsOneWidget);
      expect(find.byTooltip('Remove'), findsOneWidget);

      final doneButton = find.ancestor(
        of: find.byIcon(Icons.done),
        matching: find.byType(IconButton),
      );
      final removeButton = find.ancestor(
        of: find.byIcon(Icons.notifications_off_outlined),
        matching: find.byType(IconButton),
      );
      expect(tester.getSize(doneButton), const Size(48, 48));
      expect(tester.getSize(removeButton), const Size(48, 48));
      Finder semanticsLabel(String label) => find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.label == label,
      );
      expect(semanticsLabel('Done'), findsOneWidget);
      expect(semanticsLabel('Remove'), findsOneWidget);
      expect(
        tester.getCenter(doneButton).dy,
        tester.getCenter(removeButton).dy,
      );
    });

    testWidgets('single Remove action keeps its label when it fits', (
      tester,
    ) async {
      await pumpCard(tester, width: 180, completed: true);

      expect(find.byTooltip('Done'), findsNothing);
      expect(find.text('Remove'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    });

    testWidgets('all-day card label never displays a delivery time', (
      tester,
    ) async {
      AppState.showNotes = NoteType.reminder;
      addTearDown(() => AppState.showNotes = NoteType.all);
      final now = DateTime.now();
      final allDayNote = Note(
        id: 43,
        title: 'All-day reminder',
        reminder: Reminder(
          dateTime: DateTime(now.year, now.month, now.day + 1, 17, 45),
          isAllDay: true,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: NoteCard(note: allDayNote, index: 0)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final context = tester.element(find.byType(NoteCard));

      expect(
        find.textContaining('ALL DAY', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining(AppState.morningTime.format(context)),
        findsNothing,
      );
      expect(allDayNote.reminder!.dateTime.hour, 0);
    });
  });
}
