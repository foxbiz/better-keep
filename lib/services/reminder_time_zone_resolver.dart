import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

class ReminderTimeZoneException implements Exception {
  const ReminderTimeZoneException(this.identifier, [this.cause]);

  final String? identifier;
  final Object? cause;

  @override
  String toString() {
    final zone = identifier?.trim();
    final description = zone == null || zone.isEmpty
        ? 'the device timezone'
        : 'timezone "$zone"';
    return cause == null
        ? 'Could not resolve $description.'
        : 'Could not resolve $description: $cause';
  }
}

/// Resolves native IANA timezone identifiers, including deprecated aliases
/// still returned by some Android releases and manufacturers.
class ReminderTimeZoneResolver {
  ReminderTimeZoneResolver._();

  static bool _initialized = false;

  static tz.Location resolve(String identifier) {
    if (!_initialized) {
      tz_data.initializeTimeZones();
      _initialized = true;
    }
    final normalized = identifier.trim();
    if (normalized.isEmpty) {
      throw const ReminderTimeZoneException(null);
    }
    try {
      return tz.getLocation(normalized);
    } catch (error) {
      throw ReminderTimeZoneException(normalized, error);
    }
  }
}
