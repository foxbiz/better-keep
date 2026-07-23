import 'package:better_keep/services/assistant_note_capture_service.dart';
import 'package:better_keep/services/assistant_notes_platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Siri saves without asking for app confirmation', () async {
    var confirmationCalls = 0;
    var saveCalls = 0;
    final bridge = AssistantNotesPlatformBridge(
      service: AssistantNoteCaptureService(
        availabilityCheck: () => true,
        save: (_) async {
          saveCalls++;
          return 7;
        },
      ),
      confirm: (_) async {
        confirmationCalls++;
        return true;
      },
    );

    final result = await bridge.handleRequest({
      'requestId': 'siri-1',
      'source': 'siri',
      'text': 'Call Sam',
    });

    expect(result, {'status': 'saved', 'noteId': 7});
    expect(confirmationCalls, 0);
    expect(saveCalls, 1);
  });

  test('Android never saves when confirmation is cancelled', () async {
    var saveCalls = 0;
    final bridge = AssistantNotesPlatformBridge(
      service: AssistantNoteCaptureService(
        availabilityCheck: () => true,
        save: (_) async {
          saveCalls++;
          return 8;
        },
      ),
      confirm: (_) async => false,
    );

    final result = await bridge.handleRequest({
      'requestId': 'android-1',
      'source': 'androidCreateNote',
      'title': 'Shopping',
      'text': 'Milk',
    });

    expect(result, {'status': 'cancelled'});
    expect(saveCalls, 0);
  });

  test('Android saves after confirmation', () async {
    final bridge = AssistantNotesPlatformBridge(
      service: AssistantNoteCaptureService(
        availabilityCheck: () => true,
        save: (_) async => 9,
      ),
      confirm: (_) async => true,
    );

    final result = await bridge.handleRequest({
      'requestId': 'android-2',
      'source': 'googleAssistant',
      'text': 'Milk',
    });

    expect(result, {'status': 'saved', 'noteId': 9});
  });

  test(
    'rejects unavailable and invalid requests before confirmation',
    () async {
      var confirmationCalls = 0;
      final unavailable = AssistantNotesPlatformBridge(
        service: AssistantNoteCaptureService(
          availabilityCheck: () => false,
          save: (_) async => 1,
        ),
        confirm: (_) async {
          confirmationCalls++;
          return true;
        },
      );

      expect(
        await unavailable.handleRequest({
          'requestId': 'android-3',
          'source': 'androidCreateNote',
          'text': 'Milk',
        }),
        {'status': 'unavailable'},
      );
      expect(
        await unavailable.handleRequest({
          'requestId': 'android-4',
          'source': 'androidCreateNote',
          'text': '  ',
        }),
        {'status': 'failed'},
      );
      expect(confirmationCalls, 0);
    },
  );
}
