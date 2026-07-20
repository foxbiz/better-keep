import 'package:better_keep/services/reminder_time_zone_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  group('ReminderTimeZoneResolver', () {
    test('resolves the deprecated Asia/Calcutta Android identifier', () {
      final location = ReminderTimeZoneResolver.resolve('Asia/Calcutta');
      final local = tz.TZDateTime(location, 2026, 7, 20, 5, 28);

      expect(location.name, 'Asia/Calcutta');
      expect(local.hour, 5);
      expect(local.minute, 28);
      expect(local.timeZoneOffset, const Duration(hours: 5, minutes: 30));
      expect(local.toUtc(), DateTime.utc(2026, 7, 19, 23, 58));
    });

    test('resolves the current Asia/Kolkata identifier', () {
      final location = ReminderTimeZoneResolver.resolve('Asia/Kolkata');
      final local = tz.TZDateTime(location, 2026, 7, 20, 5, 28);

      expect(location.name, 'Asia/Kolkata');
      expect(local.timeZoneOffset, const Duration(hours: 5, minutes: 30));
      expect(local.toUtc(), DateTime.utc(2026, 7, 19, 23, 58));
    });

    test('resolves UTC without changing the instant', () {
      final location = ReminderTimeZoneResolver.resolve('UTC');
      final local = tz.TZDateTime(location, 2026, 7, 20, 5, 28);

      expect(local.timeZoneOffset, Duration.zero);
      expect(local.toUtc(), DateTime.utc(2026, 7, 20, 5, 28));
    });

    test('fails closed for an unknown non-UTC identifier', () {
      expect(
        () => ReminderTimeZoneResolver.resolve('Unknown/Better_Keep'),
        throwsA(
          isA<ReminderTimeZoneException>().having(
            (error) => error.identifier,
            'identifier',
            'Unknown/Better_Keep',
          ),
        ),
      );
    });

    test('fails closed for an empty native identifier', () {
      expect(
        () => ReminderTimeZoneResolver.resolve('  '),
        throwsA(isA<ReminderTimeZoneException>()),
      );
    });
  });
}
