import 'package:better_keep/services/reminder_session_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReminderSessionService.resetCacheForTesting();
  });

  test('signed-out is the fail-closed default', () async {
    expect(await ReminderSessionService.isSignedIn(), isFalse);
  });

  test('session signal is durable across Flutter isolates', () async {
    await ReminderSessionService.setSignedIn(true);
    ReminderSessionService.resetCacheForTesting();
    expect(await ReminderSessionService.isSignedIn(), isTrue);

    await ReminderSessionService.setSignedIn(false);
    ReminderSessionService.resetCacheForTesting();
    expect(await ReminderSessionService.isSignedIn(), isFalse);
  });
}
