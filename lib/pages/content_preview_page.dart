import 'package:better_keep/services/markdown_import_service.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/markdown_converter.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// A page to preview content (markdown or text) before importing as a note
/// or inserting into an existing note.
///
/// Used for:
/// - File import preview (shared files via intent)
/// - Clipboard paste preview (paste as formatted text)
class ContentPreviewPage extends StatefulWidget {
  /// The title to display in the app bar
  final String title;

  /// The raw content to preview
  final String content;

  /// Whether to treat the content as markdown
  final bool isMarkdown;

  /// When true, shows a done button (✓) instead of add button (+)
  /// and returns the Document on confirmation instead of creating a new note
  final bool insertMode;

  const ContentPreviewPage({
    super.key,
    required this.title,
    required this.content,
    required this.isMarkdown,
    this.insertMode = false,
  });

  @override
  State<ContentPreviewPage> createState() => _ContentPreviewPageState();
}

class _ContentPreviewPageState extends State<ContentPreviewPage> {
  bool _isProcessing = false;
  late QuillController _previewController;

  String get _noteTitle =>
      widget.title.replaceAll(RegExp(r'\.(txt|md|markdown)$'), '');

  @override
  void initState() {
    super.initState();
    _initPreviewController();
  }

  void _initPreviewController() {
    if (widget.isMarkdown) {
      // Convert markdown to Quill Document for preview
      final document = MarkdownConverter.markdownToDocument(widget.content);
      _previewController = QuillController(
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
        readOnly: true,
      );
    } else {
      // Plain text - create simple document
      final document = Document()..insert(0, widget.content);
      _previewController = QuillController(
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
        readOnly: true,
      );
    }
  }

  @override
  void dispose() {
    _previewController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foregroundColor = theme.colorScheme.onSurface;
    final backgroundColor = theme.colorScheme.surface;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        actions: [
          if (_isProcessing)
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
              icon: Icon(widget.insertMode ? Icons.check : Icons.add),
              tooltip: widget.insertMode ? 'Insert' : 'Import as Note',
              onPressed: widget.insertMode ? _confirmInsert : _importAsNote,
            ),
        ],
      ),
      body: _buildQuillPreview(theme, foregroundColor, backgroundColor),
    );
  }

  Widget _buildQuillPreview(
    ThemeData theme,
    Color foregroundColor,
    Color backgroundColor,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: QuillEditor.basic(
        controller: _previewController,
        config: QuillEditorConfig(
          scrollable: false,
          padding: EdgeInsets.zero,
          autoFocus: false,
          expands: false,
          showCursor: false,
          enableInteractiveSelection: true,
          enableSelectionToolbar: false,
          customLeadingBlockBuilder: customLeadingBlockBuilder,
          customStyles: buildQuillStyles(
            foregroundColor: foregroundColor,
            backgroundColor: backgroundColor,
          ),
        ),
      ),
    );
  }

  /// Confirm insertion - returns the document to the caller
  void _confirmInsert() {
    Navigator.of(context).pop(_previewController.document);
  }

  /// Import as a new note
  Future<void> _importAsNote() async {
    setState(() => _isProcessing = true);

    try {
      final Note note;

      if (widget.isMarkdown) {
        // Process markdown: download media, normalize headers, convert to Quill
        note = await MarkdownImportService.importMarkdown(
          title: _noteTitle,
          markdownContent: widget.content,
        );
      } else {
        // Plain text: just create a simple note
        note = await MarkdownImportService.importPlainText(
          title: _noteTitle,
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
      _showError('Failed to import: $e');
      setState(() => _isProcessing = false);
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
