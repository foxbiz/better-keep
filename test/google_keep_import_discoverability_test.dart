import 'package:better_keep/components/google_keep_import_card.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/google_keep_import_page.dart';
import 'package:better_keep/pages/home/google_keep_import_visibility.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Home uses a compact outlined Google Keep import action', (
    tester,
  ) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: () {},
                child: Text(l10n.createYourFirstNote),
              ),
              const SizedBox(height: 8),
              const GoogleKeepImportButton(),
            ],
          ),
        ),
      ),
    );

    expect(find.text(l10n.createYourFirstNote), findsOneWidget);
    expect(find.text(l10n.googleKeepImportTitle), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, l10n.googleKeepImportTitle),
      findsOneWidget,
    );
    expect(find.text(l10n.googleKeepImportHelpSubtitle), findsNothing);
    expect(find.byType(Card), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);

    await tester.tap(find.text(l10n.googleKeepImportTitle));
    await tester.pumpAndSettle();

    expect(find.byType(GoogleKeepImportPage), findsOneWidget);
  });

  testWidgets('Help card keeps its descriptive presentation and navigation', (
    tester,
  ) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(_app(const Scaffold(body: GoogleKeepImportCard())));

    expect(find.byType(Card), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text(l10n.googleKeepImportHelpSubtitle), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    await tester.tap(find.text(l10n.googleKeepImportTitle));
    await tester.pumpAndSettle();

    expect(find.byType(GoogleKeepImportPage), findsOneWidget);
  });

  testWidgets('ZIP chooser is the importer’s only source action', (
    tester,
  ) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(_app(const GoogleKeepImportPage()));

    expect(
      find.widgetWithText(FilledButton, l10n.googleKeepChooseZip),
      findsOneWidget,
    );
    expect(find.text('Choose extracted Keep folder'), findsNothing);
    expect(find.byIcon(Icons.folder_open), findsNothing);
  });

  test('only a genuinely empty, unfiltered Home shows the import action', () {
    expect(
      shouldShowGoogleKeepImportAction(
        isSearchMode: false,
        isAllNotesView: true,
        hasLabelFilters: false,
        isInsideFolder: false,
        isFolderMode: false,
        hasStoredNotes: false,
      ),
      isTrue,
    );
  });

  for (final scenario in <({String name, bool Function() isVisible})>[
    (name: 'search results', isVisible: () => _visibility(isSearchMode: true)),
    (
      name: 'label-filtered results',
      isVisible: () => _visibility(hasLabelFilters: true),
    ),
    (
      name: 'label or color folders',
      isVisible: () => _visibility(isInsideFolder: true),
    ),
    (name: 'folder mode', isVisible: () => _visibility(isFolderMode: true)),
    (
      name: 'archive, trash, or reminder views',
      isVisible: () => _visibility(isAllNotesView: false),
    ),
    (
      name: 'Home with archived or trashed notes',
      isVisible: () => _visibility(hasStoredNotes: true),
    ),
  ]) {
    test('${scenario.name} does not show the import action', () {
      expect(scenario.isVisible(), isFalse);
    });
  }
}

bool _visibility({
  bool isSearchMode = false,
  bool isAllNotesView = true,
  bool hasLabelFilters = false,
  bool isInsideFolder = false,
  bool isFolderMode = false,
  bool hasStoredNotes = false,
}) => shouldShowGoogleKeepImportAction(
  isSearchMode: isSearchMode,
  isAllNotesView: isAllNotesView,
  hasLabelFilters: hasLabelFilters,
  isInsideFolder: isInsideFolder,
  isFolderMode: isFolderMode,
  hasStoredNotes: hasStoredNotes,
);

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);
