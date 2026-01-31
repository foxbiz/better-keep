import 'package:flutter/widgets.dart';
import 'package:better_keep/l10n/app_localizations.dart';

/// Extension to easily access AppLocalizations from BuildContext
extension L10nHelper on BuildContext {
  /// Get the AppLocalizations instance for this context.
  /// Throws if AppLocalizations is not found in the widget tree.
  AppLocalizations get l10n => AppLocalizations.of(this)!;

  /// Get the AppLocalizations instance for this context, or null if not found.
  AppLocalizations? get l10nOrNull => AppLocalizations.of(this);
}
