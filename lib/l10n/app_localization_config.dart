import 'package:better_keep/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Locales intentionally exposed by Better Keep.
///
/// Keep this list separate from the generated ARB locale list: the Turkish
/// catalog is maintained for completeness but is not enabled in the app yet.
const List<Locale> betterKeepSupportedLocales = <Locale>[
  Locale('en'),
  Locale('ja'),
  Locale('ko'),
  Locale('id'),
  Locale('pt', 'BR'),
  Locale('zh'),
];

/// Localization delegates shared by the startup shell and the main app.
const List<LocalizationsDelegate<dynamic>> betterKeepLocalizationDelegates =
    <LocalizationsDelegate<dynamic>>[
      ...AppLocalizations.localizationsDelegates,
      FlutterQuillLocalizations.delegate,
    ];
