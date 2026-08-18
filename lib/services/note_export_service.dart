import 'dart:convert';

import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:better_keep/services/note_document_projection.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';

/// Export format options
enum ExportFormat { markdown, html, text }

/// Service for exporting notes in various formats
class NoteExportService {
  static final NoteExportService _instance = NoteExportService._internal();
  factory NoteExportService() => _instance;
  NoteExportService._internal();

  /// Get export content in the specified format
  String getExportContent(
    Note note,
    QuillController controller,
    ExportFormat format,
  ) {
    switch (format) {
      case ExportFormat.markdown:
        return ExportDataService().noteToMarkdown(note);
      case ExportFormat.html:
        final markdown = ExportDataService().noteToMarkdown(note);
        return md.markdownToHtml(
          markdown,
          extensionSet: md.ExtensionSet.gitHubFlavored,
        );
      case ExportFormat.text:
        return NoteDocumentProjection.toPlainText(controller.document);
    }
  }

  /// Get file extension for the format
  String getFileExtension(ExportFormat format) {
    switch (format) {
      case ExportFormat.markdown:
        return '.md';
      case ExportFormat.html:
        return '.html';
      case ExportFormat.text:
        return '.txt';
    }
  }

  /// Get MIME type for the format
  String getMimeType(ExportFormat format) {
    switch (format) {
      case ExportFormat.markdown:
        return 'text/markdown';
      case ExportFormat.html:
        return 'text/html';
      case ExportFormat.text:
        return 'text/plain';
    }
  }

  /// Sanitize filename for saving
  String sanitizeFileName(String name) {
    if (name.isEmpty) name = currentAppLocalizations().untitled;
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .substring(0, name.length > 50 ? 50 : name.length)
        .trim();
  }

  /// Save note as file and share
  Future<void> saveAs(
    Note note,
    QuillController controller,
    ExportFormat format,
  ) async {
    try {
      final content = getExportContent(note, controller, format);
      final l10n = currentAppLocalizations();
      final fileName = sanitizeFileName(note.title ?? l10n.untitled);
      final ext = getFileExtension(format);
      final mimeType = getMimeType(format);
      final contentBytes = utf8.encode(content);

      if (kIsWeb) {
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile.fromData(
                Uint8List.fromList(contentBytes),
                name: '$fileName$ext',
                mimeType: mimeType,
              ),
            ],
          ),
        );
        return;
      }

      final fs = await fileSystem();
      final filePath = path.join(await fs.cacheDir, '$fileName$ext');
      await fs.writeString(filePath, content);

      await SharePlus.instance.share(
        ShareParams(files: [XFile(filePath)], title: '$fileName$ext'),
      );
    } catch (error, stackTrace) {
      AppLogger.error('Failed to export note', error, stackTrace);
      snackbar(currentAppLocalizations().failedToExportNote, Colors.red);
    }
  }

  /// Copy note content to clipboard
  Future<void> copyAs(
    Note note,
    QuillController controller,
    ExportFormat format,
  ) async {
    try {
      final content = getExportContent(note, controller, format);
      await Clipboard.setData(ClipboardData(text: content));
      snackbar(currentAppLocalizations().copiedToClipboard, Colors.green);
    } catch (error, stackTrace) {
      AppLogger.error('Failed to copy exported note', error, stackTrace);
      snackbar(currentAppLocalizations().failedToCopyNote, Colors.red);
    }
  }
}
