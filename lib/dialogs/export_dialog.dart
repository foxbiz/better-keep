import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/note_export_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Shows export options dialog or bottom sheet based on screen size
void showExportOptions(
  BuildContext context,
  Note note,
  QuillController controller,
) {
  final isLargeScreen = MediaQuery.of(context).size.width >= 600;

  if (isLargeScreen) {
    _showExportDialog(context, note, controller);
  } else {
    _showExportBottomSheet(context, note, controller);
  }
}

/// Shows copy options dialog or bottom sheet based on screen size
void showCopyOptions(
  BuildContext context,
  Note note,
  QuillController controller,
) {
  final isLargeScreen = MediaQuery.of(context).size.width >= 600;

  if (isLargeScreen) {
    _showCopyDialog(context, note, controller);
  } else {
    _showCopyBottomSheet(context, note, controller);
  }
}

void _showExportDialog(
  BuildContext context,
  Note note,
  QuillController controller,
) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Save as'),
      content: _SaveOptionsContent(note: note, controller: controller),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'),
        ),
      ],
    ),
  );
}

void _showCopyDialog(
  BuildContext context,
  Note note,
  QuillController controller,
) {
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Copy as'),
      content: _CopyOptionsContent(note: note, controller: controller),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'),
        ),
      ],
    ),
  );
}

void _showExportBottomSheet(
  BuildContext context,
  Note note,
  QuillController controller,
) {
  showModalBottomSheet(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Save as',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _SaveOptionsContent(note: note, controller: controller),
          ],
        ),
      ),
    ),
  );
}

void _showCopyBottomSheet(
  BuildContext context,
  Note note,
  QuillController controller,
) {
  showModalBottomSheet(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                'Copy as',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _CopyOptionsContent(note: note, controller: controller),
          ],
        ),
      ),
    ),
  );
}

class _SaveOptionsContent extends StatelessWidget {
  final Note note;
  final QuillController controller;

  const _SaveOptionsContent({required this.note, required this.controller});

  @override
  Widget build(BuildContext context) {
    final service = NoteExportService();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(Icons.description),
          title: Text('Markdown (.md)'),
          onTap: () {
            Navigator.pop(context);
            service.saveAs(note, controller, ExportFormat.markdown);
          },
        ),
        ListTile(
          leading: Icon(Icons.code),
          title: Text('HTML (.html)'),
          onTap: () {
            Navigator.pop(context);
            service.saveAs(note, controller, ExportFormat.html);
          },
        ),
        ListTile(
          leading: Icon(Icons.text_snippet),
          title: Text('Plain Text (.txt)'),
          onTap: () {
            Navigator.pop(context);
            service.saveAs(note, controller, ExportFormat.text);
          },
        ),
      ],
    );
  }
}

class _CopyOptionsContent extends StatelessWidget {
  final Note note;
  final QuillController controller;

  const _CopyOptionsContent({required this.note, required this.controller});

  @override
  Widget build(BuildContext context) {
    final service = NoteExportService();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(Icons.description),
          title: Text('Markdown'),
          onTap: () {
            Navigator.pop(context);
            service.copyAs(note, controller, ExportFormat.markdown);
          },
        ),
        ListTile(
          leading: Icon(Icons.code),
          title: Text('HTML'),
          onTap: () {
            Navigator.pop(context);
            service.copyAs(note, controller, ExportFormat.html);
          },
        ),
        ListTile(
          leading: Icon(Icons.text_snippet),
          title: Text('Plain Text'),
          onTap: () {
            Navigator.pop(context);
            service.copyAs(note, controller, ExportFormat.text);
          },
        ),
      ],
    );
  }
}
