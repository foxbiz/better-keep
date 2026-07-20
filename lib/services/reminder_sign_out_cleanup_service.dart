import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/local_notification_service.dart';
import 'package:better_keep/services/reminder_navigation_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';

class ReminderSignOutCleanupService {
  ReminderSignOutCleanupService._();

  static Future<void> cancelDeliveries() async {
    final noteIds = <int>[];
    try {
      final rows = await AppState.db.query(Note.model, columns: const ['id']);
      for (final row in rows) {
        final id = row['id'];
        if (id is int) noteIds.add(id);
      }
    } catch (error, stackTrace) {
      await AppLogger.error(
        'Failed to enumerate reminders during sign-out',
        error,
        stackTrace,
      );
    }
    for (final noteId in noteIds) {
      await LocalNotificationService.instance.cancelReminder(noteId);
    }
    final discovered = await LocalNotificationService.instance
        .cancelAllReminderDeliveries();
    await ReminderNavigationService.instance.clearForSignOut();
    await AppLogger.log(
      'Signed-out reminder cleanup complete: '
      'knownNotes=${noteIds.length}, discoveredDeliveries=$discovered',
    );
  }
}
