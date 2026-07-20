import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all-day reminder export contains a date but no fabricated time', () {
    final markdown = ExportDataService().noteToMarkdown(
      Note(
        title: 'Date-only reminder',
        reminder: Reminder(
          dateTime: DateTime(2026, 7, 20, 17, 45),
          isAllDay: true,
        ),
      ),
    );

    expect(markdown, contains('2026-07-20 (All day)'));
    expect(markdown, isNot(contains('2026-07-20T00:00')));
    expect(markdown, isNot(contains('17:45')));
  });

  test('timed reminder export preserves its selected time', () {
    final markdown = ExportDataService().noteToMarkdown(
      Note(
        title: 'Timed reminder',
        reminder: Reminder(dateTime: DateTime(2026, 7, 20, 17, 45)),
      ),
    );

    expect(markdown, contains('2026-07-20T17:45:00.000'));
  });
}
