import 'dart:ui' show PlatformDispatcher;

import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:flutter/widgets.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/state.dart';

/// Extension to easily access AppLocalizations from BuildContext
extension L10nHelper on BuildContext {
  /// Get the AppLocalizations instance for this context.
  /// Throws if AppLocalizations is not found in the widget tree.
  AppLocalizations get l10n => AppLocalizations.of(this)!;

  /// Get the AppLocalizations instance for this context, or null if not found.
  AppLocalizations? get l10nOrNull => AppLocalizations.of(this);
}

/// Resolves localization for background services that cannot safely retain a
/// [BuildContext]. UI widgets should continue to use [L10nHelper.l10n].
AppLocalizations currentAppLocalizations() {
  final requested = AppState.locale ?? PlatformDispatcher.instance.locale;
  final supported = betterKeepSupportedLocales.any(
    (locale) => locale.languageCode == requested.languageCode,
  );
  return lookupAppLocalizations(
    supported ? Locale(requested.languageCode) : const Locale('en'),
  );
}
