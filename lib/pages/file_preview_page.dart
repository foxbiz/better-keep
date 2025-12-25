import 'package:better_keep/services/markdown_import_service.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:markdown/markdown.dart' as md;

/// A page to preview files (markdown or text) before importing as a note
class FilePreviewPage extends StatefulWidget {
  final String fileName;
  final String content;
  final bool isMarkdown;

  const FilePreviewPage({
    super.key,
    required this.fileName,
    required this.content,
    required this.isMarkdown,
  });

  @override
  State<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends State<FilePreviewPage> {
  bool _isImporting = false;

  String get _title =>
      widget.fileName.replaceAll(RegExp(r'\.(txt|md|markdown)$'), '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fileName, style: const TextStyle(fontSize: 16)),
        actions: [
          if (_isImporting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Import as Note',
              onPressed: _importAsNote,
            ),
        ],
      ),
      body: widget.isMarkdown
          ? _buildMarkdownPreview(theme)
          : _buildTextPreview(theme),
    );
  }

  Widget _buildMarkdownPreview(ThemeData theme) {
    // Convert markdown to HTML
    final htmlContent = md.markdownToHtml(
      widget.content,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    );

    final isDark = theme.brightness == Brightness.dark;
    final codeBackground = theme.colorScheme.surfaceContainerHighest;
    final textColor = theme.colorScheme.onSurface;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Html(
        data: htmlContent,
        style: {
          'body': Style(
            color: textColor,
            fontSize: FontSize(16),
            lineHeight: const LineHeight(1.6),
          ),
          'h1': Style(
            fontSize: FontSize(28),
            fontWeight: FontWeight.bold,
            margin: Margins.only(top: 16, bottom: 8),
          ),
          'h2': Style(
            fontSize: FontSize(24),
            fontWeight: FontWeight.bold,
            margin: Margins.only(top: 14, bottom: 6),
          ),
          'h3': Style(
            fontSize: FontSize(20),
            fontWeight: FontWeight.bold,
            margin: Margins.only(top: 12, bottom: 4),
          ),
          'p': Style(margin: Margins.only(bottom: 12)),
          'code': Style(
            backgroundColor: codeBackground,
            padding: HtmlPaddings.symmetric(horizontal: 4, vertical: 2),
            fontFamily: 'monospace',
            fontSize: FontSize(14),
          ),
          'pre': Style(
            backgroundColor: codeBackground,
            padding: HtmlPaddings.all(12),
            margin: Margins.symmetric(vertical: 8),
          ),
          'pre code': Style(
            backgroundColor: Colors.transparent,
            padding: HtmlPaddings.zero,
            color: isDark ? Colors.white : Colors.black87,
          ),
          'blockquote': Style(
            border: Border(
              left: BorderSide(color: theme.colorScheme.primary, width: 4),
            ),
            padding: HtmlPaddings.only(left: 12),
            margin: Margins.symmetric(vertical: 8),
            fontStyle: FontStyle.italic,
          ),
          'a': Style(
            color: theme.colorScheme.primary,
            textDecoration: TextDecoration.underline,
          ),
          'ul': Style(margin: Margins.only(bottom: 12)),
          'ol': Style(margin: Margins.only(bottom: 12)),
          'li': Style(margin: Margins.only(bottom: 4)),
          'img': Style(margin: Margins.symmetric(vertical: 8)),
          'table': Style(border: Border.all(color: theme.dividerColor)),
          'th': Style(
            backgroundColor: codeBackground,
            padding: HtmlPaddings.all(8),
            fontWeight: FontWeight.bold,
          ),
          'td': Style(
            padding: HtmlPaddings.all(8),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.5),
            ),
          ),
        },
      ),
    );
  }

  Widget _buildTextPreview(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        widget.content,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontFamily: 'monospace',
          height: 1.5,
        ),
      ),
    );
  }

  Future<void> _importAsNote() async {
    setState(() => _isImporting = true);

    try {
      final Note note;

      if (widget.isMarkdown) {
        // Process markdown: download media, normalize headers, convert to Quill
        note = await MarkdownImportService.importMarkdown(
          title: _title,
          markdownContent: widget.content,
        );
      } else {
        // Plain text: just create a simple note
        note = await MarkdownImportService.importPlainText(
          title: _title,
          textContent: widget.content,
        );
      }

      if (!mounted) return;

      // Navigate to note editor, replacing this preview page
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => NoteEditor(note: note)),
      );
    } catch (e) {
      if (!mounted) return;
      _showError('Failed to import file: $e');
      setState(() => _isImporting = false);
    }
  }

  void _showError(String message) {
    final scaffoldMessenger = AppState.scaffoldMessengerKey.currentState;
    if (scaffoldMessenger != null) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }
}
