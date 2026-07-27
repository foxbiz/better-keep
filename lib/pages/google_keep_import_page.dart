import 'dart:async';

import 'package:better_keep/services/import/google_keep_import_service.dart';
import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:better_keep/services/review_prompt_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class GoogleKeepImportPage extends StatefulWidget {
  final GoogleKeepImportService? service;

  const GoogleKeepImportPage({super.key, this.service});

  @override
  State<GoogleKeepImportPage> createState() => _GoogleKeepImportPageState();
}

class _GoogleKeepImportPageState extends State<GoogleKeepImportPage> {
  late final GoogleKeepImportService _service;
  KeepImportProgress? _progress;
  KeepImportReport? _report;
  KeepImportCancellationToken? _cancellationToken;
  String? _error;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? GoogleKeepImportService();
  }

  Future<void> _chooseZip() async {
    final selection = await FilePicker.pickFiles(
      dialogTitle: 'Choose a Google Takeout ZIP',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      withData: kIsWeb,
      allowMultiple: false,
    );
    if (selection == null || selection.files.isEmpty) return;
    final file = selection.files.single;
    await _runImport(
      (token) => _service.importZip(
        bytes: file.bytes,
        filePath: file.path,
        cancellationToken: token,
        onProgress: _onProgress,
      ),
    );
  }

  Future<void> _chooseDirectory() async {
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose the extracted Google Keep folder',
    );
    if (directory == null) return;
    await _runImport(
      (token) => _service.importDirectory(
        directoryPath: directory,
        cancellationToken: token,
        onProgress: _onProgress,
      ),
    );
  }

  Future<void> _runImport(
    Future<KeepImportReport> Function(KeepImportCancellationToken token)
    operation,
  ) async {
    final token = KeepImportCancellationToken();
    setState(() {
      _cancellationToken = token;
      _importing = true;
      _progress = null;
      _report = null;
      _error = null;
    });
    try {
      final report = await operation(token);
      if (!mounted) return;
      setState(() => _report = report);
      if (report.imported > 0) {
        unawaited(
          ReviewPromptService.instance.recordPositiveMilestone(
            ReviewMilestone.googleKeepImport,
          ),
        );
      }
    } on KeepImportCancelled {
      if (mounted) {
        setState(() => _error = 'Import cancelled. No notes were saved.');
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _cancellationToken = null;
        });
      }
    }
  }

  void _onProgress(KeepImportProgress progress) {
    if (mounted) setState(() => _progress = progress);
  }

  Future<void> _shareReport() async {
    final report = _report;
    if (report == null) return;
    await SharePlus.instance.share(
      ShareParams(
        title: 'Better Keep Google Keep import report',
        text: report.toShareText(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Import from Google Keep')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lock_outline, color: colorScheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Your archive stays on this device',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Better Keep validates and converts the Google Takeout archive locally. '
                    'It does not upload the ZIP to a conversion service. Notes only enter '
                    'the normal optional sync flow after the import commits successfully.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Before you start',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            '1. Open Google Takeout and select only Keep.\n'
            '2. Create and download the export.\n'
            '3. Choose the ZIP below. Exact re-imports are skipped by default.',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _importing ? null : _chooseZip,
            icon: const Icon(Icons.archive_outlined),
            label: const Text('Choose Takeout ZIP'),
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _importing ? null : _chooseDirectory,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose extracted Keep folder'),
            ),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              final uri = Uri.parse(
                'https://support.google.com/accounts/answer/3024190',
              );
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open Google Takeout instructions'),
          ),
          if (_importing || _progress != null) ...[
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _progress?.message ?? 'Starting import…',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress?.fraction),
                    if (_importing) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _cancellationToken?.cancel,
                        icon: const Icon(Icons.close),
                        label: const Text('Cancel import'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Card(
              color: colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],
          if (_report != null) ...[
            const SizedBox(height: 24),
            _ImportSummary(report: _report!, onShare: _shareReport),
          ],
          const SizedBox(height: 24),
          Text(
            'Safety limits',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'ZIP files are limited to 100 MB compressed, 500 MB expanded, '
            '20,000 files, and 50 MB per file. Unsafe paths, symbolic links, '
            'and malformed archives are rejected before notes are saved.',
          ),
        ],
      ),
    );
  }
}

class _ImportSummary extends StatelessWidget {
  final KeepImportReport report;
  final VoidCallback onShare;

  const _ImportSummary({required this.report, required this.onShare});

  @override
  Widget build(BuildContext context) {
    final counts = [
      ('Imported', report.imported, Icons.check_circle_outline),
      ('Skipped', report.skipped, Icons.skip_next_outlined),
      ('Warnings', report.warnings, Icons.warning_amber_outlined),
      ('Unsupported', report.unsupported, Icons.block_outlined),
      ('Failed', report.failed, Icons.error_outline),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Import complete',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: counts
                  .map(
                    (item) => Chip(
                      avatar: Icon(item.$3, size: 18),
                      label: Text('${item.$1}: ${item.$2}'),
                    ),
                  )
                  .toList(),
            ),
            if (report.issues.isNotEmpty) ...[
              const SizedBox(height: 16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Review import details'),
                children: report.issues
                    .take(100)
                    .map(
                      (issue) => ListTile(
                        dense: true,
                        leading: Icon(switch (issue.kind) {
                          KeepImportIssueKind.warning =>
                            Icons.warning_amber_outlined,
                          KeepImportIssueKind.failure => Icons.error_outline,
                          KeepImportIssueKind.unsupported =>
                            Icons.block_outlined,
                        }),
                        title: Text(issue.message),
                        subtitle: Text(issue.source),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onShare,
              icon: const Icon(Icons.ios_share),
              label: const Text('Share full report'),
            ),
          ],
        ),
      ),
    );
  }
}
