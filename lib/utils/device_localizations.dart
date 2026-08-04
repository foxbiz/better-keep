import 'package:better_keep/l10n/app_localizations.dart';

/// Localizes only app-generated device placeholders. User-assigned and
/// provider-supplied device names are preserved verbatim.
String localizedDeviceName(AppLocalizations l10n, String name) {
  return switch (name) {
    'Unknown Device' => l10n.unknownDevice,
    'Web Browser' => l10n.webBrowser,
    _ => name,
  };
}
