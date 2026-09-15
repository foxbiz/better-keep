import 'dart:async';
import 'dart:typed_data';

import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/google_keep_import_page.dart';
import 'package:better_keep/services/import/google_keep_import_service.dart';
import 'package:better_keep/services/import/keep_archive_input.dart';
import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late FilePickerPlatform original;
  late _Picker picker;
  late _ImportService service;

  setUp(() {
    original = FilePickerPlatform.instance;
    picker = _Picker();
    service = _ImportService();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() => FilePickerPlatform.instance = original);

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: GoogleKeepImportPage(service: service),
      ),
    );
    // Browser async streams need a real event-loop turn; animation pumping
    // alone can otherwise starve their completion under the test clock.
    await tester.runAsync(() async {
      await tester.tap(find.text(l10n.googleKeepChooseZip));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  testWidgets('picker cancellation does not start an import', (tester) async {
    await open(tester);
    await tester.pumpAndSettle();
    expect(service.calls, 0);
    expect(picker.type, FileType.custom);
    expect(picker.extensions, ['zip']);
    expect(find.text(l10n.googleKeepImportFailed), findsNothing);
  });

  for (final knownLength in [true, false]) {
    testWidgets(
      'streams ZIP with ${knownLength ? 'reported' : 'async'} length',
      (tester) async {
        final file = _File(knownLength: knownLength);
        picker.result = Future.value(file);
        await open(tester);
        await tester.pumpAndSettle();
        expect(service.bytes, [1, 2, 3, 4]);
        expect(file.lengthCalls, knownLength ? 0 : 1);
        expect(file.subscriptions, 1);
        expect(service.calls, 1);
        expect(find.text(l10n.googleKeepImportComplete), findsOneWidget);
      },
    );
  }

  testWidgets('oversized ZIP is rejected before reading its stream', (
    tester,
  ) async {
    final file = _File(reportedLength: 101 * KeepImportOptions.mebibyte);
    picker.result = Future.value(file);
    await open(tester);
    await tester.pumpAndSettle();
    expect(file.subscriptions, 0);
    expect(find.text(l10n.googleKeepImportFailed), findsOneWidget);
  });

  for (final failure in ['picker', 'length', 'stream']) {
    testWidgets('$failure failure is shown and allows retry', (tester) async {
      final file = _File(knownLength: false, failure: failure);
      picker.failure = failure == 'picker';
      picker.result = Future.value(file);
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.text(l10n.googleKeepImportFailed), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, l10n.googleKeepChooseZip),
      );
      expect(button.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('pending picker disables repeated submissions', (tester) async {
    final pending = Completer<PlatformFile?>();
    picker.result = pending.future;
    await open(tester);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l10n.googleKeepChooseZip),
    );
    expect(button.onPressed, isNull);
    expect(picker.calls, 1);
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(service.calls, 0);
  });

  testWidgets('cancelling during async length does not read or import', (
    tester,
  ) async {
    final pending = Completer<int>();
    final file = _File(knownLength: false, pendingLength: pending.future);
    picker.result = Future.value(file);
    await open(tester);
    await tester.ensureVisible(find.text(l10n.googleKeepCancelImport));
    await tester.pump();
    await tester.tap(find.text(l10n.googleKeepCancelImport));
    pending.complete(4);
    await tester.pumpAndSettle();
    expect(service.calls, 0);
    expect(file.subscriptions, 0);
    expect(find.text(l10n.googleKeepImportCancelled), findsOneWidget);
  });
}

class _Picker extends FilePickerPlatform {
  Future<PlatformFile?> result = Future.value();
  bool failure = false;
  int calls = 0;
  FileType? type;
  List<String>? extensions;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    this.type = type;
    extensions = allowedExtensions;
    if (failure) throw StateError('picker failed');
    return result;
  }
}

final class _File extends PlatformFile {
  _File({
    this.knownLength = true,
    this.reportedLength = 4,
    this.failure,
    this.pendingLength,
  });
  final bool knownLength;
  final int reportedLength;
  final String? failure;
  final Future<int>? pendingLength;
  int lengthCalls = 0;
  int subscriptions = 0;

  @override
  String get name => 'Keep.zip';
  @override
  Uri get uri => Uri.parse('content://isolated/Keep.zip');
  @override
  Never get xFile => throw StateError('must use streaming API');
  @override
  int? lengthSync() => knownLength ? reportedLength : null;
  @override
  Future<int> length() async {
    lengthCalls++;
    if (failure == 'length') throw StateError('length failed');
    return pendingLength ?? Future.value(reportedLength);
  }

  @override
  Future<Uint8List> readAsBytes() => throw StateError('must not read eagerly');
  @override
  Stream<Uint8List> readAsByteStream() async* {
    subscriptions++;
    yield Uint8List.fromList([1, 2]);
    if (failure == 'stream') throw StateError('read failed');
    yield Uint8List.fromList([3, 4]);
  }
}

class _ImportService extends GoogleKeepImportService {
  int calls = 0;
  Uint8List? bytes;

  @override
  Future<KeepImportReport> importZip(
    KeepArchiveInput input, {
    KeepImportOptions options = const KeepImportOptions(),
    KeepImportCancellationToken? cancellationToken,
    KeepImportProgressCallback? onProgress,
  }) async {
    calls++;
    bytes = await input.read(
      maxBytes: options.maxArchiveBytes,
      cancellationToken: cancellationToken!,
    );
    return KeepImportReport(
      source: ImportSource.googleKeepTakeout,
      startedAt: DateTime(2026),
      completedAt: DateTime(2026),
      discovered: 0,
      imported: 0,
      skipped: 0,
      failed: 0,
      warnings: 0,
      unsupported: 0,
      issues: const [],
    );
  }
}
