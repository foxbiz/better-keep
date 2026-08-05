import 'dart:async';

import 'package:better_keep/services/import/google_keep_import_service.dart';
import 'package:better_keep/services/import/keep_import_models.dart';
import 'package:better_keep/services/review_prompt_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
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
      dialogTitle: context.l10n.googleKeepChooseZip,
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
      dialogTitle: context.l10n.googleKeepChooseFolder,
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
        setState(() => _error = context.l10n.googleKeepImportCancelled);
      }
    } catch (error, stackTrace) {
      AppLogger.error('Google Keep import failed', error, stackTrace);
      if (mounted) {
        setState(() => _error = context.l10n.googleKeepImportFailed);
      }
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
        title: context.l10n.googleKeepImportReportTitle,
        text: report.toShareText(),
      ),
    );
  }

  String _progressMessage(BuildContext context) => switch (_progress?.phase) {
    KeepImportPhase.validating => context.l10n.googleKeepImportValidating,
    KeepImportPhase.parsing => context.l10n.googleKeepImportParsing,
    KeepImportPhase.preparingAttachments =>
      context.l10n.googleKeepImportPreparingAttachments,
    KeepImportPhase.saving => context.l10n.googleKeepImportSaving,
    KeepImportPhase.complete => context.l10n.googleKeepImportComplete,
    null => context.l10n.googleKeepImportStarting,
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.googleKeepImportTitle)),
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
                          context.l10n.googleKeepImportPrivacyTitle,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(context.l10n.googleKeepImportPrivacyDescription),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.googleKeepImportBeforeStart,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(context.l10n.googleKeepImportInstructions),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _importing ? null : _chooseZip,
            icon: const Icon(Icons.archive_outlined),
            label: Text(context.l10n.googleKeepChooseZip),
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _importing ? null : _chooseDirectory,
              icon: const Icon(Icons.folder_open),
              label: Text(context.l10n.googleKeepChooseFolder),
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
            label: Text(context.l10n.googleKeepOpenTakeoutInstructions),
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
                      _progressMessage(context),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: _progress?.fraction),
                    if (_importing) ...[
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _cancellationToken?.cancel,
                        icon: const Icon(Icons.close),
                        label: Text(context.l10n.googleKeepCancelImport),
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
            context.l10n.googleKeepSafetyLimits,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(context.l10n.googleKeepSafetyDescription),
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
      (
        context.l10n.googleKeepImported,
        report.imported,
        Icons.check_circle_outline,
      ),
      (
        context.l10n.googleKeepSkipped,
        report.skipped,
        Icons.skip_next_outlined,
      ),
      (
        context.l10n.googleKeepWarnings,
        report.warnings,
        Icons.warning_amber_outlined,
      ),
      (
        context.l10n.googleKeepUnsupported,
        report.unsupported,
        Icons.block_outlined,
      ),
      (context.l10n.googleKeepFailed, report.failed, Icons.error_outline),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.googleKeepImportComplete,
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
                title: Text(context.l10n.googleKeepReviewDetails),
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
              label: Text(context.l10n.googleKeepShareReport),
            ),
          ],
        ),
      ),
    );
  }
}
