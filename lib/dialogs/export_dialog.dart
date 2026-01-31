import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/note_export_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
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
      title: Text(context.l10n.saveAs),
      content: _SaveOptionsContent(note: note, controller: controller),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
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
      title: Text(context.l10n.copyAs),
      content: _CopyOptionsContent(note: note, controller: controller),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
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
                context.l10n.saveAs,
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
                context.l10n.copyAs,
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
    final l10n = context.l10n;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.description),
          title: Text(l10n.markdownFile),
          onTap: () {
            Navigator.pop(context);
            service.saveAs(note, controller, ExportFormat.markdown);
          },
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: Text(l10n.htmlFile),
          onTap: () {
            Navigator.pop(context);
            service.saveAs(note, controller, ExportFormat.html);
          },
        ),
        ListTile(
          leading: const Icon(Icons.text_snippet),
          title: Text(l10n.plainTextFile),
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
    final l10n = context.l10n;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.description),
          title: Text(l10n.markdown),
          onTap: () {
            Navigator.pop(context);
            service.copyAs(note, controller, ExportFormat.markdown);
          },
        ),
        ListTile(
          leading: const Icon(Icons.code),
          title: Text(l10n.html),
          onTap: () {
            Navigator.pop(context);
            service.copyAs(note, controller, ExportFormat.html);
          },
        ),
        ListTile(
          leading: const Icon(Icons.text_snippet),
          title: Text(l10n.plainText),
          onTap: () {
            Navigator.pop(context);
            service.copyAs(note, controller, ExportFormat.text);
          },
        ),
      ],
    );
  }
}
