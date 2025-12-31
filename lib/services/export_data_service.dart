import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:better_keep/models/label.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/attachments/attachment.dart';
import 'package:better_keep/services/auth/auth_service.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system/file_system.dart';
import 'package:better_keep/utils/logger.dart';
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

  /// Export status message
  ValueNotifier<String> status = ValueNotifier('');

  /// Convert a single note to Markdown format (public API)
  /// This can be used to export individual notes
  String noteToMarkdown(Note note) => _noteToMarkdown(note);

  /// Export all user data to a ZIP file
  /// Returns the path to the exported ZIP file, or null if export failed
  Future<String?> exportAllData({
    bool includeAttachments = true,
    Function(String)? onStatus,
  }) async {
    try {
      progress.value = 0.0;
      status.value = 'Preparing export...';
      onStatus?.call(status.value);

      final archive = Archive();

      // 1. Export notes
      status.value = 'Exporting notes...';
      onStatus?.call(status.value);
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
      status.value = 'Exporting notes as Markdown...';
      onStatus?.call(status.value);

      for (final note in unlockedNotes) {
        try {
          final markdown = _noteToMarkdown(note);
          final fileName = _sanitizeFileName(note.title ?? 'Untitled');
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
          'note':
              'These notes are PIN-locked. The content is encrypted and cannot be exported as Markdown.',
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
      status.value = 'Exporting labels...';
      onStatus?.call(status.value);

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
        status.value = 'Exporting attachments...';
        onStatus?.call(status.value);

        int totalAttachments = 0;
        for (final note in notes) {
          totalAttachments += note.attachments.length;
        }

        int processedAttachments = 0;

        for (final note in notes) {
          for (final attachment in note.attachments) {
            try {
              // Use decrypted file reading to handle encrypted attachments
              final fileData = await _getAttachmentDataDecrypted(attachment);
              if (fileData != null && fileData.isNotEmpty) {
                final filePath = 'attachments/note_${note.id}/${attachment.id}';

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
      status.value = 'Creating export package...';
      onStatus?.call(status.value);

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
      final readme =
          '''
Better Keep Notes - Data Export
================================

This archive contains your exported data from Better Keep Notes.

Contents:
- metadata.json: Export information and statistics
- notes/: Folder containing your notes
  - *.md: Unlocked notes exported as Markdown files
  - locked_notes.json: PIN-locked notes (encrypted, cannot be read without PIN)
- notes.json: All notes in JSON format (for backup/import)
- labels.json: All your labels in JSON format
- attachments/: Folder containing all note attachments (images, audio, sketches)

Notes Format:
Unlocked notes are exported as Markdown (.md) files for easy reading.
Each Markdown file includes:
- Title as heading
- Labels as tags
- Creation/update timestamps
- Note content with formatting
- Links to attachments (relative paths)

Locked Notes:
PIN-locked notes cannot be decrypted without the original PIN.
They are exported as JSON with encrypted content in locked_notes.json.

Attachments:
Attachments are organized in folders by note ID:
- attachments/note_<id>/<filename>

Attachments in Markdown files are linked with relative paths:
- ../attachments/note_<id>/<filename>

For support or questions, contact: contact@betterkeep.app

Exported on: ${DateTime.now().toIso8601String()}
''';
      final readmeBytes = utf8.encode(readme);
      archive.addFile(_createArchiveFile('README.txt', readmeBytes));

      progress.value = 0.9;

      // Log archive stats before encoding
      AppLogger.log(
        'Archive stats: ${archive.files.length} files before ZIP encoding',
      );

      // 5. Encode the archive to ZIP
      status.value = 'Compressing data...';
      onStatus?.call(status.value);

      // Use STORE level (no compression) for maximum compatibility
      final encoder = ZipEncoder();
      final zipData = encoder.encode(archive, level: DeflateLevel.none);
      if (zipData.isEmpty) {
        throw Exception('Failed to encode ZIP archive');
      }

      // 6. Save the ZIP file
      status.value = 'Saving export file...';
      onStatus?.call(status.value);

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
      status.value = 'Export complete!';
      onStatus?.call(status.value);

      return exportPath;
    } catch (e, stackTrace) {
      AppLogger.error('Error exporting data', e, stackTrace);
      status.value = 'Export failed: $e';
      onStatus?.call(status.value);
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
        title: 'Better Keep Notes Export',
        text: 'My Better Keep Notes data export',
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
      'reminder': note.reminder != null
          ? {
              'dateTime': note.reminder!.dateTime.toIso8601String(),
              'isAllDay': note.reminder!.isAllDay,
            }
          : null,
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
  Map<String, dynamic> _attachmentToExportJson(Attachment attachment) {
    switch (attachment.type) {
      case AttachmentType.image:
        return {
          'type': 'image',
          'fileName': attachment.image!.id,
          'originalPath': attachment.image!.path,
          'aspectRatio': attachment.image!.aspectRatio,
          'size': attachment.image!.dimension,
        };
      case AttachmentType.sketch:
        return {
          'type': 'sketch',
          'fileName': attachment.sketch!.id,
          'originalPath': attachment.sketch!.previewPath,
          'strokeCount': attachment.sketch!.strokes.length,
        };
      case AttachmentType.audio:
        return {
          'type': 'audio',
          'fileName': attachment.recording!.id,
          'originalPath': attachment.recording!.path,
          'length': attachment.recording!.length,
          'title': attachment.recording!.title,
          'transcript': attachment.recording!.transcript,
        };
    }
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
  Future<Uint8List?> _getAttachmentDataDecrypted(Attachment attachment) async {
    String? path;

    switch (attachment.type) {
      case AttachmentType.image:
        path = attachment.image!.path;
        break;
      case AttachmentType.sketch:
        path = attachment.sketch!.previewPath;
        break;
      case AttachmentType.audio:
        path = attachment.recording!.path;
        break;
    }

    // Handle remote URLs
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return null; // Skip remote files
    }

    try {
      final fs = await fileSystem();
      if (await fs.exists(path)) {
        // Use readEncryptedBytes which automatically decrypts if needed
        return await readEncryptedBytes(path);
      }
    } catch (e) {
      AppLogger.error('Error reading attachment file', e);
    }

    return null;
  }

  /// Sanitize a string for use as a filename
  String _sanitizeFileName(String name) {
    if (name.isEmpty) return 'untitled';
    // Remove or replace invalid filename characters
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .substring(0, name.length > 50 ? 50 : name.length)
        .trim();
  }

  /// Convert a Note to Markdown format
  String _noteToMarkdown(Note note) {
    final buffer = StringBuffer();

    // Content - convert Quill Delta to Markdown (main content first)
    if (note.content != null && note.content!.isNotEmpty) {
      try {
        final deltaJson = json.decode(note.content!) as List;
        buffer.write(_deltaToMarkdown(deltaJson, note.id));
      } catch (e) {
        // Fallback to plain text if delta parsing fails
        // Add title as heading if using plain text fallback
        final title = note.title?.isNotEmpty == true ? note.title! : 'Untitled';
        buffer.writeln('# $title');
        buffer.writeln();
        buffer.writeln(note.plainText ?? '');
      }
    } else {
      // No content, just add title
      final title = note.title?.isNotEmpty == true ? note.title! : 'Untitled';
      buffer.writeln('# $title');
      buffer.writeln();
    }

    // Attachments section
    if (note.attachments.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('---');
      buffer.writeln();
      buffer.writeln('## Attachments');
      buffer.writeln();

      for (final attachment in note.attachments) {
        final relativePath = '../attachments/note_${note.id}/${attachment.id}';

        switch (attachment.type) {
          case AttachmentType.image:
            buffer.writeln('![${attachment.id}]($relativePath)');
            buffer.writeln();
            break;
          case AttachmentType.sketch:
            buffer.writeln('![Sketch: ${attachment.id}]($relativePath)');
            buffer.writeln();
            break;
          case AttachmentType.audio:
            final recording = attachment.recording!;
            buffer.writeln('🎵 **Audio:** [${attachment.id}]($relativePath)');
            if (recording.title?.isNotEmpty == true) {
              buffer.writeln('  - Title: ${recording.title}');
            }
            if (recording.length > 0) {
              final duration = Duration(milliseconds: recording.length);
              buffer.writeln(
                '  - Duration: ${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
              );
            }
            if (recording.transcript?.isNotEmpty == true) {
              buffer.writeln('  - Transcript: ${recording.transcript}');
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
      metadata.add('Labels: ${note.labels}');
    }
    if (note.createdAt != null) {
      metadata.add('Created: ${note.createdAt!.toIso8601String()}');
    }
    if (note.updatedAt != null) {
      metadata.add('Updated: ${note.updatedAt!.toIso8601String()}');
    }
    if (note.pinned) metadata.add('📌 Pinned');
    if (note.archived) metadata.add('📦 Archived');
    if (note.trashed) metadata.add('🗑️ Trashed');
    if (note.reminder != null) {
      metadata.add('⏰ Reminder: ${note.reminder!.dateTime.toIso8601String()}');
    }
    buffer.writeln(metadata.join(' • '));
    buffer.writeln('</small>');

    return buffer.toString();
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
    }

    buffer.writeln('$prefix$text$suffix');
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

    return result;
  }
}
