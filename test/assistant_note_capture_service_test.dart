import 'dart:async';
import 'dart:convert';

import 'package:better_keep/services/assistant_note_capture_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AssistantNoteCaptureRequest', () {
    test('normalizes title and body', () {
      const request = AssistantNoteCaptureRequest(
        requestId: 'request-1',
        source: 'siri',
        title: '  Shopping  ',
        text: '  Milk\nEggs  ',
      );

      expect(request.normalizedTitle, 'Shopping');
      expect(request.normalizedText, 'Milk\nEggs');
      expect(request.isValid, isTrue);
    });

    test(
      'accepts body-only, title-only, unicode, multiline, and long text',
      () {
        const bodyOnly = AssistantNoteCaptureRequest(
          requestId: 'body',
          source: 'siri',
          text: 'こんにちは\n🦊',
        );
        const titleOnly = AssistantNoteCaptureRequest(
          requestId: 'title',
          source: 'androidCreateNote',
          title: 'Idea',
        );
        final longText = AssistantNoteCaptureRequest(
          requestId: 'long',
          source: 'siri',
          text: List.filled(5000, 'a').join(),
        );

        expect(bodyOnly.isValid, isTrue);
        expect(titleOnly.isValid, isTrue);
        expect(longText.isValid, isTrue);
      },
    );

    test('rejects whitespace-only and incomplete requests', () {
      const whitespace = AssistantNoteCaptureRequest(
        requestId: 'blank',
        source: 'siri',
        title: ' ',
        text: '\n\t',
      );
      const noId = AssistantNoteCaptureRequest(source: 'siri', requestId: '');
      const noSource = AssistantNoteCaptureRequest(
        source: '',
        requestId: 'request',
        text: 'hello',
      );

      expect(whitespace.isValid, isFalse);
      expect(noId.isValid, isFalse);
      expect(noSource.isValid, isFalse);
    });
  });

  group('PlainTextNoteWriter', () {
    test('creates a canonical Quill delta', () {
      expect(jsonDecode(PlainTextNoteWriter.buildContent('Hello\nworld')), [
        {'insert': 'Hello\nworld'},
        {'insert': '\n'},
      ]);
    });

    test('creates a valid empty body for title-only notes', () {
      expect(jsonDecode(PlainTextNoteWriter.buildContent(null)), [
        {'insert': '\n'},
      ]);
    });
  });

  group('AssistantNoteCaptureService', () {
    const request = AssistantNoteCaptureRequest(
      requestId: 'request-1',
      source: 'siri',
      text: 'Remember this',
    );

    test('returns unavailable without calling persistence', () async {
      var saveCalls = 0;
      final service = AssistantNoteCaptureService(
        availabilityCheck: () => false,
        save: (_) async {
          saveCalls++;
          return 1;
        },
      );

      final result = await service.capture(request);

      expect(result.status, AssistantNoteCaptureStatus.unavailable);
      expect(saveCalls, 0);
    });

    test('returns failed when persistence fails', () async {
      final negativeResult = AssistantNoteCaptureService(
        availabilityCheck: () => true,
        save: (_) async => -1,
      );
      final throwing = AssistantNoteCaptureService(
        availabilityCheck: () => true,
        save: (_) async => throw StateError('save failed'),
      );

      expect(
        (await negativeResult.capture(request)).status,
        AssistantNoteCaptureStatus.failed,
      );
      expect(
        (await throwing.capture(request)).status,
        AssistantNoteCaptureStatus.failed,
      );
    });

    test('uses normalized text and the Voice Notes system label', () async {
      String? capturedTitle;
      String? capturedText;
      String? capturedLabel;
      final service = AssistantNoteCaptureService(
        availabilityCheck: () => true,
        writer: ({title, text, required labelName}) async {
          capturedTitle = title;
          capturedText = text;
          capturedLabel = labelName;
          return 12;
        },
      );

      final result = await service.capture(
        const AssistantNoteCaptureRequest(
          requestId: 'voice-label',
          source: 'siri',
          title: '  Idea  ',
          text: '  Unicode 🦊  ',
        ),
      );

      expect(result.status, AssistantNoteCaptureStatus.saved);
      expect(capturedTitle, 'Idea');
      expect(capturedText, 'Unicode 🦊');
      expect(capturedLabel, 'Voice Notes');
    });

    test('supports the shared-text label through the common service', () async {
      String? capturedLabel;
      final service = AssistantNoteCaptureService(
        availabilityCheck: () => true,
        labelName: 'Shared Text',
        writer: ({title, text, required labelName}) async {
          capturedLabel = labelName;
          return 13;
        },
      );

      final result = await service.capture(
        const AssistantNoteCaptureRequest(
          requestId: 'shared-label',
          source: 'sharedText',
          text: 'Imported text',
        ),
      );

      expect(result.status, AssistantNoteCaptureStatus.saved);
      expect(capturedLabel, 'Shared Text');
    });

    test('deduplicates concurrent and completed request IDs', () async {
      final saveStarted = Completer<void>();
      final allowSave = Completer<void>();
      var saveCalls = 0;
      final service = AssistantNoteCaptureService(
        availabilityCheck: () => true,
        save: (_) async {
          saveCalls++;
          saveStarted.complete();
          await allowSave.future;
          return 42;
        },
      );

      final first = service.capture(request);
      await saveStarted.future;
      final duplicateWhileSaving = service.capture(request);
      allowSave.complete();

      expect((await first).noteId, 42);
      expect((await duplicateWhileSaving).noteId, 42);
      expect((await service.capture(request)).noteId, 42);
      expect(saveCalls, 1);
    });

    test('serializes different request IDs', () async {
      final events = <String>[];
      final firstCanFinish = Completer<void>();
      final service = AssistantNoteCaptureService(
        availabilityCheck: () => true,
        save: (value) async {
          events.add('start-${value.requestId}');
          if (value.requestId == 'first') await firstCanFinish.future;
          events.add('end-${value.requestId}');
          return value.requestId == 'first' ? 1 : 2;
        },
      );

      final first = service.capture(
        const AssistantNoteCaptureRequest(
          requestId: 'first',
          source: 'siri',
          text: 'one',
        ),
      );
      final second = service.capture(
        const AssistantNoteCaptureRequest(
          requestId: 'second',
          source: 'siri',
          text: 'two',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, ['start-first']);
      firstCanFinish.complete();
      await Future.wait([first, second]);
      expect(events, [
        'start-first',
        'end-first',
        'start-second',
        'end-second',
      ]);
    });
  });
}
