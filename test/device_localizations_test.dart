import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/utils/device_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final ja = lookupAppLocalizations(const Locale('ja'));

  test('app-generated device placeholders are localized', () {
    expect(localizedDeviceName(en, 'Unknown Device'), en.unknownDevice);
    expect(localizedDeviceName(ja, 'Unknown Device'), ja.unknownDevice);
    expect(localizedDeviceName(ja, 'Web Browser'), ja.webBrowser);
  });

  test('real device names remain unchanged', () {
    expect(localizedDeviceName(ja, 'Ajit’s MacBook'), 'Ajit’s MacBook');
  });
}
