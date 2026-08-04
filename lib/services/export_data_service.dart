import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/app_progress.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Service for exporting user data to a ZIP file
class ExportDataService {
  static final ExportDataService _instance = ExportDataService._internal();
  factory ExportDataService() => _instance;
  ExportDataService._internal();

  /// Unix file mode for regular files (rw-r--r-- = 0644)
  static const int _fileMode =
      0x81A4; // 0100644 in octal (regular file + 644 permissions)

  /// Create an ArchiveFile with proper Unix attributes for macOS compatibility
  ArchiveFile _createArchiveFile(String path, List<int> data) {
    final file = ArchiveFile(path, data.length, data);
    file.mode = _fileMode;
    return file;
  }

  /// Export progress callback
  ValueNotifier<double> progress = ValueNotifier(0.0);

  /// Typed export status; presentation text is resolved by the UI.
  final ValueNotifier<ExportPhase> exportStatus = ValueNotifier(
    ExportPhase.idle,
  );

  /// Convert a single note to Markdown format (public API)
  /// This can be used to export individual notes
  /// Set [includeMetadata] to false to exclude attachments section and metadata footer
  String noteToMarkdown(Note note, {bool includeMetadata = true}) =>
      _noteToMarkdown(note, includeMetadata: includeMetadata);

  /// Export all user data to a ZIP file
  /// Returns the path to the exported ZIP file, or null if export failed
  Future<String?> exportAllData({
    bool includeAttachments = true,
    ValueChanged<ExportPhase>? onStatus,
  }) async {
    try {
      final l10n = currentAppLocalizations();
      progress.value = 0.0;
      exportStatus.value = ExportPhase.preparing;
      onStatus?.call(exportStatus.value);

      final archive = Archive();

      // 1. Export notes
      exportStatus.value = ExportPhase.notes;
      onStatus?.call(exportStatus.value);
      progress.value = 0.1;

      final allNotes = await Note.get(NoteType.all);
      final trashedNotes = await Note.get(NoteType.trashed);
      final archivedNotes = await Note.get(NoteType.archived);

      // Combine all notes (some may overlap, so use a Set by ID)
      final notesMap = <int, Note>{};
      for (final note in [...allNotes, ...trashedNotes, ...archivedNotes]) {
        if (note.id != null) {
          notesMap[note.id!] = note;
        }
      }
      final notes = notesMap.values.toList();

      // Separate locked and unlocked notes
      final lockedNotes = notes.where((n) => n.locked).toList();
      final unlockedNotes = notes.where((n) => !n.locked).toList();

      // Export unlocked notes as individual Markdown files
      exportStatus.value = ExportPhase.notes;
      onStatus?.call(exportStatus.value);

      for (final note in unlockedNotes) {
        try {
          final markdown = _noteToMarkdown(note);
          final fileName = _sanitizeFileName(
            note.title ?? currentAppLocalizations().untitled,
          );
          final notePath = 'notes/${note.id}_$fileName.md';
          final markdownBytes = utf8.encode(markdown);
          archive.addFile(_createArchiveFile(notePath, markdownBytes));
        } catch (e) {
          AppLogger.error('Error exporting note ${note.id}: $e');
        }
      }

      // Export locked notes as JSON (since we can't decrypt them without PIN)
      if (lockedNotes.isNotEmpty) {
        final lockedNotesJson = lockedNotes
            .map((note) => _noteToExportJson(note))
            .toList();
        final lockedJsonString = const JsonEncoder.withIndent('  ').convert({
          'exportedAt': DateTime.now().toIso8601String(),
          'version': '1.0',
          'noteCount': lockedNotes.length,
          'notes': lockedNotesJson,
          'note': l10n.lockedExportExplanation,
        });
        final lockedJsonBytes = utf8.encode(lockedJsonString);
        archive.addFile(
          _createArchiveFile('notes/locked_notes.json', lockedJsonBytes),
        );
      }

      // Also keep a full notes.json for backup/import purposes
      final notesJson = notes.map((note) => _noteToExportJson(note)).toList();

      // Add notes.json to archive
      final notesJsonString = const JsonEncoder.withIndent('  ').convert({
        'exportedAt': DateTime.now().toIso8601String(),
        'version': '1.0',
        'noteCount': notes.length,
        'notes': notesJson,
      });
      final notesJsonBytes = utf8.encode(notesJsonString);
      archive.addFile(_createArchiveFile('notes.json', notesJsonBytes));

      progress.value = 0.2;

      // 2. Export labels
      exportStatus.value = ExportPhase.labels;
      onStatus?.call(exportStatus.value);

      final labels = await Label.get();
      final labelsJson = labels.map((label) => label.toJson()).toList();

      final labelsJsonString = const JsonEncoder.withIndent('  ').convert({
        'exportedAt': DateTime.now().toIso8601String(),
        'version': '1.0',
        'labelCount': labels.length,
        'labels': labelsJson,
      });
      final labelsJsonBytes = utf8.encode(labelsJsonString);
      archive.addFile(_createArchiveFile('labels.json', labelsJsonBytes));

      progress.value = 0.3;

      // 3. Export attachments if requested
      if (includeAttachments) {
        exportStatus.value = ExportPhase.attachments;
        onStatus?.call(exportStatus.value);

        int totalAttachments = 0;
        for (final note in notes) {
          totalAttachments += note.attachments.length;
        }

        int processedAttachments = 0;

        for (final note in notes) {
          for (final attachment in note.attachments) {
            try {
              // Use decrypted file reading to handle encrypted attachments
              final fileData = await _getAttachmentDataDecrypted(
                note,
                attachment,
              );
              if (fileData != null && fileData.isNotEmpty) {
                final fileName = _getAttachmentFileName(attachment);
                final noteFolder = 'attachments/note_${note.id}';
                final filePath = '$noteFolder/$fileName';

                archive.addFile(_createArchiveFile(filePath, fileData));
                AppLogger.log(
                  'Added attachment: $filePath (${fileData.length} bytes)',
                );
              }
            } catch (e) {
              AppLogger.error('Error exporting attachment: $e');
            }

            processedAttachments++;
            progress.value =
                0.3 + (0.5 * processedAttachments / totalAttachments);
          }
        }
      }

      progress.value = 0.8;

      // 4. Add metadata file
      exportStatus.value = ExportPhase.packaging;
      onStatus?.call(exportStatus.value);

      final user = AuthService.currentUser;
      final metadataJson = const JsonEncoder.withIndent('  ').convert({
        'exportedAt': DateTime.now().toIso8601String(),
        'exportVersion': '1.0',
        'appVersion': '1.0.2',
        'userEmail': user?.email ?? 'unknown',
        'noteCount': notes.length,
        'labelCount': labels.length,
        'includesAttachments': includeAttachments,
      });
      final metadataBytes = utf8.encode(metadataJson);
      archive.addFile(_createArchiveFile('metadata.json', metadataBytes));

      // Add a README file
      final readme = l10n.dataExportReadme(DateTime.now().toIso8601String());
      final readmeBytes = utf8.encode(readme);
      archive.addFile(_createArchiveFile('README.txt', readmeBytes));

      progress.value = 0.9;

      // Log archive stats before encoding
      AppLogger.log(
        'Archive stats: ${archive.files.length} files before ZIP encoding',
      );

      // 5. Encode the archive to ZIP
      exportStatus.value = ExportPhase.compressing;
      onStatus?.call(exportStatus.value);

      // Use STORE level (no compression) for maximum compatibility
      final encoder = ZipEncoder();
      final zipData = encoder.encode(archive, level: DeflateLevel.none);
      if (zipData.isEmpty) {
        throw Exception('Failed to encode ZIP archive');
      }

      // 6. Save the ZIP file
      exportStatus.value = ExportPhase.saving;
      onStatus?.call(exportStatus.value);

      final fileName =
          'better_keep_export_${DateTime.now().millisecondsSinceEpoch}.zip';
      String exportPath;

      final zipBytes = Uint8List.fromList(zipData);

      if (kIsWeb) {
        // On web, trigger download
        exportPath = await _saveForWeb(zipBytes, fileName);
      } else {
        // On native platforms, save to downloads or documents
        exportPath = await _saveForNative(zipBytes, fileName);
      }

      progress.value = 1.0;
      exportStatus.value = ExportPhase.complete;
      onStatus?.call(exportStatus.value);

      return exportPath;
    } catch (e, stackTrace) {
      AppLogger.error('Error exporting data', e, stackTrace);
      exportStatus.value = ExportPhase.failed;
      onStatus?.call(exportStatus.value);
      return null;
    }
  }

  /// Share the exported ZIP file
  Future<void> shareExport(String filePath) async {
    if (kIsWeb) {
      // Web already downloads the file
      return;
    }

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(filePath)],
        title: currentAppLocalizations().dataExportTitle,
        text: currentAppLocalizations().dataExportShareText,
      ),
    );
  }

  /// Convert a Note to an exportable JSON format
  Map<String, dynamic> _noteToExportJson(Note note) {
    return {
      'id': note.id,
      'title': note.title,
      'content': note.content,
      'plainText': note.plainText,
      'labels': note.labels,
      'attachments': note.attachments
          .map((a) => _attachmentToExportJson(a))
          .toList(),
      'reminder': note.reminder?.toJson(),
      'createdAt': note.createdAt?.toIso8601String(),
      'updatedAt': note.updatedAt?.toIso8601String(),
      'archived': note.archived,
      'trashed': note.trashed,
      'pinned': note.pinned,
      'completed': note.completed,
      'locked': note.locked,
      'readOnly': note.readOnly,
      'color': note.color.toARGB32(),
    };
  }

  /// Convert an attachment to exportable JSON
  Map<String, dynamic> _attachmentToExportJson(NoteAttachment attachment) {
    switch (attachment.type) {
      case AttachmentType.image:
        return {
          'type': 'image',
          'fileName': _getFileNameFromPath(attachment.image!.src),
          'originalPath': attachment.image!.src,
          'aspectRatio': attachment.image!.aspectRatio,
          'size': attachment.image!.size,
        };
      case AttachmentType.sketch:
        return {
          'type': 'sketch',
          'fileName': _getFileNameFromPath(
            attachment.sketch!.previewImage ?? '',
          ),
          'originalPath': attachment.sketch!.previewImage,
          'strokeCount': attachment.sketch!.strokes.length,
        };
      case AttachmentType.audio:
        return {
          'type': 'audio',
          'fileName': _getFileNameFromPath(attachment.recording!.src),
          'originalPath': attachment.recording!.src,
          'length': attachment.recording!.length,
          'title': attachment.recording!.title,
          'transcript': attachment.recording!.transcript,
        };
    }
  }

  /// Get a filename for an attachment
  String _getAttachmentFileName(NoteAttachment attachment) {
    switch (attachment.type) {
      case AttachmentType.image:
        return _getFileNameFromPath(attachment.image!.src);
      case AttachmentType.sketch:
        final path = attachment.sketch!.previewImage ?? 'sketch.png';
        return _getFileNameFromPath(path);
      case AttachmentType.audio:
        return _getFileNameFromPath(attachment.recording!.src);
    }
  }

  /// Extract filename from a path (and sanitize for ZIP)
  String _getFileNameFromPath(String path) {
    final parts = path.split('/');
    final fileName = parts.isNotEmpty ? parts.last : 'unknown';
    // Sanitize the filename for ZIP compatibility
    return fileName
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
  }

  /// Save ZIP for web (download)
  Future<String> _saveForWeb(Uint8List data, String fileName) async {
    // Use the file system's saveToGallery which handles web downloads
    // For ZIP files, we'll use a different approach
    final fs = await fileSystem();
    final docDir = await fs.documentDir;
    final path = '$docDir/$fileName';
    await fs.writeBytes(path, data);

    // Trigger download using share_plus or similar
    // On web, Share.shareXFiles will trigger a download
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(data, name: fileName, mimeType: 'application/zip'),
        ],
      ),
    );

    return path;
  }

  /// Save ZIP for native platforms
  Future<String> _saveForNative(Uint8List data, String fileName) async {
    String savePath;

    if (Platform.isAndroid) {
      // Try to save to Downloads folder
      try {
        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (await downloadsDir.exists()) {
          savePath = '${downloadsDir.path}/$fileName';
        } else {
          final docDir = await getApplicationDocumentsDirectory();
          savePath = '${docDir.path}/$fileName';
        }
      } catch (e) {
        final docDir = await getApplicationDocumentsDirectory();
        savePath = '${docDir.path}/$fileName';
      }
    } else if (Platform.isIOS || Platform.isMacOS) {
      final docDir = await getApplicationDocumentsDirectory();
      savePath = '${docDir.path}/$fileName';
    } else {
      // Windows/Linux - try Downloads folder
      try {
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          savePath = '${downloadsDir.path}/$fileName';
        } else {
          final docDir = await getApplicationDocumentsDirectory();
          savePath = '${docDir.path}/$fileName';
        }
      } catch (e) {
        final docDir = await getApplicationDocumentsDirectory();
        savePath = '${docDir.path}/$fileName';
      }
    }

    final file = File(savePath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data);

    return savePath;
  }

  /// Get attachment data with automatic decryption for encrypted files
  Future<Uint8List?> _getAttachmentDataDecrypted(
    Note note,
    NoteAttachment attachment,
  ) async {
    String? path;

    switch (attachment.type) {
      case AttachmentType.image:
        path = attachment.image!.src;
        break;
      case AttachmentType.sketch:
        if (attachment.sketch!.requiresLegacyMigration) return null;
        path = attachment.sketch!.previewImage;
        break;
      case AttachmentType.audio:
        path = attachment.recording!.src;
        break;
    }

    if (path == null || path.isEmpty) {
      return null;
    }

    // Handle remote URLs
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return null; // Skip remote files
    }

    try {
      final fs = await fileSystem();
      if (await fs.exists(path)) {
        // Use readEncryptedBytes which automatically decrypts if needed
        if (note.locked && !note.unlocked) return null;
        return await note.readAttachmentForSession(path);
      }
    } catch (e) {
      AppLogger.error('Error reading attachment file', e);
    }

    return null;
  }

  /// Sanitize a string for use as a filename
  String _sanitizeFileName(String name) {
    if (name.isEmpty) name = currentAppLocalizations().untitled;
    // Remove or replace invalid filename characters
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .substring(0, name.length > 50 ? 50 : name.length)
        .trim();
  }

  /// Convert a Note to Markdown format
  String _noteToMarkdown(Note note, {bool includeMetadata = true}) {
    final buffer = StringBuffer();
    final l10n = currentAppLocalizations();

    // Content - convert Quill Delta to Markdown (main content first)
    if (note.content != null && note.content!.isNotEmpty) {
      try {
        final deltaJson = json.decode(note.content!) as List;
        buffer.write(_deltaToMarkdown(deltaJson, note.id));
      } catch (e) {
        // Fallback to plain text if delta parsing fails
        // Add title as heading if using plain text fallback
        final title = note.title?.isNotEmpty == true
            ? note.title!
            : l10n.untitled;
        buffer.writeln('# $title');
        buffer.writeln();
        buffer.writeln(note.plainText ?? '');
      }
    } else {
      // No content, just add title
      final title = note.title?.isNotEmpty == true
          ? note.title!
          : l10n.untitled;
      buffer.writeln('# $title');
      buffer.writeln();
    }

    // Only include attachments and metadata if requested (for full export)
    if (!includeMetadata) {
      return buffer.toString();
    }

    // Attachments section
    if (note.attachments.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
      buffer.writeln('## ${l10n.exportAttachments}');
      buffer.writeln();

      for (final attachment in note.attachments) {
        final fileName = _getAttachmentFileName(attachment);
        final relativePath = '../attachments/note_${note.id}/$fileName';

        switch (attachment.type) {
          case AttachmentType.image:
            buffer.writeln('![$fileName]($relativePath)');
            buffer.writeln();
            break;
          case AttachmentType.sketch:
            buffer.writeln('![${l10n.sketch}: $fileName]($relativePath)');
            buffer.writeln();
            break;
          case AttachmentType.audio:
            final recording = attachment.recording!;
            buffer.writeln('🎵 **${l10n.audio}:** [$fileName]($relativePath)');
            if (recording.title?.isNotEmpty == true) {
              buffer.writeln('  - ${l10n.title}: ${recording.title}');
            }
            if (recording.length > 0) {
              final duration = Duration(milliseconds: recording.length);
              buffer.writeln(
                '  - ${l10n.duration}: ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
              );
            }
            if (recording.transcript?.isNotEmpty == true) {
              buffer.writeln('  - ${l10n.transcript}: ${recording.transcript}');
            }
            buffer.writeln();
            break;
        }
      }
    }

    // Metadata at bottom in small text
    buffer.writeln();
    buffer.writeln('---');
    buffer.writeln();
    buffer.writeln('<small>');
    final metadata = <String>[];
    if (note.labels?.isNotEmpty == true) {
      // Clean up labels string - remove leading/trailing commas and spaces
      final cleanLabels = note.labels!
          .split(',')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .join(', ');
      if (cleanLabels.isNotEmpty) {
        metadata.add('${l10n.labels}: $cleanLabels');
      }
    }
    if (note.createdAt != null) {
      metadata.add('${l10n.created}: ${note.createdAt!.toIso8601String()}');
    }
    if (note.updatedAt != null) {
      metadata.add('${l10n.updated}: ${note.updatedAt!.toIso8601String()}');
    }
    if (note.pinned) metadata.add('📌 ${l10n.pinnedNotes}');
    if (note.archived) metadata.add('📦 ${l10n.archivedNotes}');
    if (note.trashed) metadata.add('🗑️ ${l10n.trash}');
    if (note.reminder != null) {
      final reminder = note.reminder!;
      metadata.add(
        '⏰ ${l10n.reminder} (${_localizedReminderType(reminder.type)}, ${_localizedRepeat(reminder.repeat)}): '
        '${_formatReminderForExport(reminder)}',
      );
    }
    buffer.writeln(metadata.join(' • '));
    buffer.writeln('</small>');

    return buffer.toString();
  }

  String _formatReminderForExport(Reminder reminder) {
    if (!reminder.isAllDay) return reminder.dateTime.toIso8601String();
    final date = reminder.dateTime;
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day (${currentAppLocalizations().allDay})';
  }

  String _localizedReminderType(ReminderType type) {
    final l10n = currentAppLocalizations();
    return switch (type) {
      ReminderType.notification => l10n.notificationReminder,
      ReminderType.alarm => l10n.alarmReminder,
      ReminderType.unsupported => l10n.reminder,
    };
  }

  String _localizedRepeat(String repeat) {
    final l10n = currentAppLocalizations();
    return switch (repeat) {
      Reminder.repeatDaily => l10n.daily,
      Reminder.repeatWeekly => l10n.weekly,
      Reminder.repeatMonthly => l10n.monthly,
      Reminder.repeatYearly => l10n.yearly,
      Reminder.repeatOnce => l10n.oneTime,
      _ => l10n.never,
    };
  }

  /// Convert Quill Delta JSON to Markdown
  String _deltaToMarkdown(List<dynamic> delta, int? noteId) {
    final buffer = StringBuffer();
    String currentLine = '';
    Map<String, dynamic>? pendingLineAttributes;

    for (final op in delta) {
      if (op is! Map) continue;

      final insert = op['insert'];
      final attributes = op['attributes'] as Map<String, dynamic>?;

      if (insert is String) {
        final lines = insert.split('\n');

        for (int i = 0; i < lines.length; i++) {
          final text = lines[i];

          if (i > 0) {
            // Process the completed line
            _writeMarkdownLine(
              buffer,
              currentLine,
              pendingLineAttributes,
              noteId,
            );
            currentLine = '';
            pendingLineAttributes = null;
          }

          // Apply inline formatting
          currentLine += _applyInlineFormatting(text, attributes);

          // If this is the last segment before a newline, capture line attributes
          if (i < lines.length - 1 || insert.endsWith('\n')) {
            pendingLineAttributes = attributes;
          }
        }
      } else if (insert is Map) {
        // Handle embeds (images, videos, etc.)
        if (insert.containsKey('image')) {
          final imageSrc = insert['image'] as String;
          currentLine += '![]($imageSrc)';
        }
      }
    }

    // Write any remaining content
    if (currentLine.isNotEmpty) {
      _writeMarkdownLine(buffer, currentLine, pendingLineAttributes, noteId);
    }

    return buffer.toString();
  }

  /// Write a line with block-level formatting
  void _writeMarkdownLine(
    StringBuffer buffer,
    String text,
    Map<String, dynamic>? attributes,
    int? noteId,
  ) {
    if (text.isEmpty && attributes == null) {
      buffer.writeln();
      return;
    }

    String prefix = '';
    String suffix = '';
    bool useHtmlWrapper = false;
    String? alignStyle;
    int indentLevel = 0;

    if (attributes != null) {
      // Headers
      if (attributes.containsKey('header')) {
        final level = attributes['header'] as int;
        prefix = '${'#' * level} ';
      }

      // Lists
      if (attributes.containsKey('list')) {
        final listType = attributes['list'];
        if (listType == 'bullet') {
          prefix = '- ';
        } else if (listType == 'ordered') {
          prefix = '1. ';
        } else if (listType == 'checked') {
          prefix = '- [x] ';
        } else if (listType == 'unchecked') {
          prefix = '- [ ] ';
        }
      }

      // Blockquote
      if (attributes.containsKey('blockquote') &&
          attributes['blockquote'] == true) {
        prefix = '> ';
      }

      // Code block
      if (attributes.containsKey('code-block') &&
          attributes['code-block'] == true) {
        buffer.writeln('```');
        buffer.writeln(text);
        buffer.writeln('```');
        return;
      }

      // Indentation
      if (attributes.containsKey('indent')) {
        final indent = attributes['indent'];
        if (indent is int) {
          indentLevel = indent;
        }
      }

      // Alignment
      if (attributes.containsKey('align')) {
        final align = attributes['align'] as String?;
        if (align != null && align != 'left') {
          alignStyle = align;
          useHtmlWrapper = true;
        }
      }
    }

    // Apply indentation (4 spaces per level for proper markdown nesting)
    String indentPrefix = '';
    if (indentLevel > 0) {
      indentPrefix = '    ' * indentLevel;
    }

    if (useHtmlWrapper) {
      // Use HTML div for alignment and indentation
      final styleProps = <String>[];
      if (alignStyle != null) {
        styleProps.add('text-align: $alignStyle');
      }
      final style = styleProps.isNotEmpty
          ? ' style="${styleProps.join('; ')}"'
          : '';
      buffer.writeln('<div$style>$indentPrefix$prefix$text$suffix</div>');
    } else {
      buffer.writeln('$indentPrefix$prefix$text$suffix');
    }
  }

  /// Apply inline formatting to text
  String _applyInlineFormatting(String text, Map<String, dynamic>? attributes) {
    if (text.isEmpty || attributes == null) return text;

    String result = text;

    // Bold
    if (attributes['bold'] == true) {
      result = '**$result**';
    }

    // Italic
    if (attributes['italic'] == true) {
      result = '*$result*';
    }

    // Strikethrough
    if (attributes['strike'] == true) {
      result = '~~$result~~';
    }

    // Code
    if (attributes['code'] == true) {
      result = '`$result`';
    }

    // Link
    if (attributes.containsKey('link')) {
      final link = attributes['link'] as String;
      result = '[$result]($link)';
    }

    // Custom font size (use HTML span)
    if (attributes.containsKey('size')) {
      final size = attributes['size'];
      if (size != null) {
        // Size can be a string like "12" or a number
        final sizeValue = size is String ? size : size.toString();
        result = '<span style="font-size: ${sizeValue}px">$result</span>';
      }
    }

    return result;
  }
}
