import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

/// Result type for paste operations
sealed class PasteResult {}

/// User cancelled the paste operation
class PasteCancelled extends PasteResult {}

/// User chose to paste as plain text
class PastePlainText extends PasteResult {
  final String text;
  PastePlainText(this.text);
}

/// User chose to paste as formatted text (needs preview navigation)
class PasteFormattedPreview extends PasteResult {
  final String markdownText;
  PasteFormattedPreview(this.markdownText);
}

/// Shows paste options dialog or bottom sheet based on screen size
///
/// Returns [PasteResult] indicating the user's choice:
/// - [PasteCancelled] if cancelled or clipboard empty
/// - [PastePlainText] with the clipboard text for plain paste
/// - [PasteFormattedPreview] with the markdown text to preview
Future<PasteResult> showPasteOptions(BuildContext context) async {
  // Check if clipboard has content
  final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);

  // Check mounted after async gap to avoid using stale context
  if (!context.mounted) return PasteCancelled();

  if (clipboardData?.text == null || clipboardData!.text!.isEmpty) {
    snackbar(context.l10n.clipboardEmpty, Colors.orange);
    return PasteCancelled();
  }

  final clipboardText = clipboardData.text!;
  final isLargeScreen = MediaQuery.of(context).size.width >= 600;

  if (isLargeScreen) {
    return await _showPasteDialog(context, clipboardText);
  } else {
    return await _showPasteBottomSheet(context, clipboardText);
  }
}

Future<PasteResult> _showPasteDialog(
  BuildContext context,
  String clipboardText,
) async {
  final result = await showDialog<PasteResult>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.pasteAs),
      content: _PasteOptionsContent(clipboardText: clipboardText),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, PasteCancelled()),
          child: Text(context.l10n.cancel),
        ),
      ],
    ),
  );
  return result ?? PasteCancelled();
}

Future<PasteResult> _showPasteBottomSheet(
  BuildContext context,
  String clipboardText,
) async {
  final result = await showModalBottomSheet<PasteResult>(
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
                context.l10n.pasteAs,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _PasteOptionsContent(clipboardText: clipboardText),
          ],
        ),
      ),
    ),
  );
  return result ?? PasteCancelled();
}

class _PasteOptionsContent extends StatelessWidget {
  final String clipboardText;

  const _PasteOptionsContent({required this.clipboardText});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.text_format),
          title: Text(context.l10n.formattedText),
          subtitle: Text(context.l10n.previewAndInsertFormatted),
          onTap: () {
            Navigator.pop(context, PasteFormattedPreview(clipboardText));
          },
        ),
        ListTile(
          leading: const Icon(Icons.text_snippet),
          title: Text(context.l10n.plainText),
          subtitle: Text(context.l10n.insertAsPlainText),
          onTap: () {
            Navigator.pop(context, PastePlainText(clipboardText));
          },
        ),
      ],
    );
  }
}

/// Inserts a document into the controller at the current cursor position
///
/// Call this from a StatefulWidget with proper mounted checks
void insertDocumentIntoController(
  QuillController controller,
  Document document,
) {
  // If no valid selection, insert at end of document
  final index = controller.selection.baseOffset >= 0
      ? controller.selection.baseOffset
      : controller.document.length - 1;
  final deltaToInsert = document.toDelta();

  // Get the operations from the delta
  final ops = deltaToInsert.toList();

  // Build a new delta that retains up to the insertion point, then inserts the content
  final composeDelta = Delta();

  // Retain everything before the insertion point
  if (index > 0) {
    composeDelta.retain(index);
  }

  // Add all operations from the document to insert (except trailing newline)
  int insertedLength = 0;
  for (int i = 0; i < ops.length; i++) {
    final op = ops[i];
    if (op.isInsert) {
      // Skip the final trailing newline that every Quill document has
      if (i == ops.length - 1 && op.data == '\n' && op.attributes == null) {
        continue;
      }

      // Add the operation with its attributes
      if (op.attributes != null && op.attributes!.isNotEmpty) {
        composeDelta.insert(op.data, op.attributes);
      } else {
        composeDelta.insert(op.data);
      }

      // Track inserted length
      if (op.data is String) {
        insertedLength += (op.data as String).length;
      } else {
        insertedLength += 1; // embeds count as 1
      }
    }
  }

  // Compose the delta into the document
  controller.compose(
    composeDelta,
    const TextSelection.collapsed(offset: 0),
    ChangeSource.local,
  );

  // Update selection to end of inserted content
  controller.updateSelection(
    TextSelection.collapsed(offset: index + insertedLength),
    ChangeSource.local,
  );
}

/// Inserts plain text into the controller at the current cursor position
///
/// Call this from a StatefulWidget with proper mounted checks
void insertPlainTextIntoController(QuillController controller, String text) {
  // If no valid selection, insert at end of document
  final index = controller.selection.baseOffset >= 0
      ? controller.selection.baseOffset
      : controller.document.length - 1;

  controller.document.insert(index, text);
  controller.updateSelection(
    TextSelection.collapsed(offset: index + text.length),
    ChangeSource.local,
  );
}
