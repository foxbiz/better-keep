import 'package:better_keep/utils/calendar_date.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('calendar day delta ignores times and preserves direction', () {
    expect(
      calendarDayDelta(
        DateTime(2026, 3, 1, 23, 59),
        DateTime(2026, 3, 15, 0, 1),
      ),
      14,
    );
    expect(
      calendarDayDelta(DateTime(2026, 3, 15), DateTime(2026, 3, 1)),
      -14,
    );
  });

  test('calendar day delta handles month and leap-year boundaries', () {
    expect(
      calendarDayDelta(DateTime(2024, 2, 28), DateTime(2024, 3, 1)),
      2,
    );
    expect(
      calendarDayDelta(DateTime(2025, 2, 28), DateTime(2025, 3, 1)),
      1,
    );
  });
}
