import 'package:better_keep/dialogs/link_dialog.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class LinkButton extends StatefulWidget {
  final QuillController controller;
  final bool readOnly;

  const LinkButton({
    super.key,
    required this.readOnly,
    required this.controller,
  });

  @override
  State<LinkButton> createState() => _LinkButtonState();
}

class _LinkButtonState extends State<LinkButton> {
  bool isLink = false;

  void _didChangeSelection() {
    setState(() {
      isLink = QuillTextLink.isSelected(widget.controller);
    });
  }

  @override
  void initState() {
    widget.controller.addListener(_didChangeSelection);
    super.initState();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_didChangeSelection);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.readOnly;

    return IconButton(
      isSelected: isLink,
      icon: const Icon(Icons.link),
      tooltip: context.l10n.link,
      onPressed: enabled ? _handleLinkPress : null,
    );
  }

  Future<void> _handleLinkPress() async {
    final controller = widget.controller;
    final selection = controller.selection;
    final hasSelection = !selection.isCollapsed;

    // Get existing link info if cursor is on a link
    final prep = QuillTextLink.prepare(controller);
    final existingText = prep.text;
    final existingUrl = prep.link;
    final isEditingExisting = existingUrl != null && existingUrl.isNotEmpty;

    // Determine initial text for dialog
    String? initialText;
    if (hasSelection) {
      // Use selected text
      initialText = controller.document.getPlainText(
        selection.start,
        selection.end - selection.start,
      );
    } else if (existingText.isNotEmpty) {
      // Use existing link text
      initialText = existingText;
    }

    final result = await showLinkDialog(
      context,
      initialText: initialText,
      initialUrl: existingUrl,
      isEditingExisting: isEditingExisting,
    );

    if (result == null) return;

    if (result.url == null) {
      // Remove link - just clear the link attribute from existing text
      if (isEditingExisting) {
        final textLink = QuillTextLink(existingText, null);
        textLink.submit(controller);
      }
      return;
    }

    if (hasSelection) {
      // Convert selected text to link
      controller.formatSelection(LinkAttribute(result.url));
    } else if (isEditingExisting) {
      // Update existing link
      final textLink = QuillTextLink(result.text, result.url);
      textLink.submit(controller);
    } else {
      // Insert new text with link at cursor position
      final index = selection.baseOffset;
      controller.document.insert(index, result.text);
      controller.formatText(
        index,
        result.text.length,
        LinkAttribute(result.url),
      );
      // Move cursor to end of inserted text
      controller.updateSelection(
        TextSelection.collapsed(offset: index + result.text.length),
        ChangeSource.local,
      );
    }
  }
}
