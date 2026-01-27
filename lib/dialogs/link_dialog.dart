import 'package:flutter/material.dart';

/// Result from the link dialog
class LinkResult {
  final String text;
  final String? url; // null means remove link

  const LinkResult({required this.text, this.url});
}

/// Shows a dialog to add/edit a link with both text and URL fields
Future<LinkResult?> showLinkDialog(
  BuildContext context, {
  String? initialText,
  String? initialUrl,
  bool isEditingExisting = false,
}) {
  return showDialog<LinkResult?>(
    context: context,
    builder: (context) => _LinkDialog(
      initialText: initialText,
      initialUrl: initialUrl,
      isEditingExisting: isEditingExisting,
    ),
  );
}

class _LinkDialog extends StatefulWidget {
  final String? initialText;
  final String? initialUrl;
  final bool isEditingExisting;

  const _LinkDialog({
    this.initialText,
    this.initialUrl,
    this.isEditingExisting = false,
  });

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _textController;
  late final TextEditingController _urlController;
  final FocusNode _textFocus = FocusNode();
  final FocusNode _urlFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText ?? '');

    // Default URL to 'https://' if no existing URL, cursor will be at end
    final defaultUrl = widget.initialUrl?.isNotEmpty == true
        ? widget.initialUrl!
        : 'https://';
    _urlController = TextEditingController(text: defaultUrl);

    // Move cursor to end of URL field after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _urlController.selection = TextSelection.collapsed(
        offset: _urlController.text.length,
      );
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _urlController.dispose();
    _textFocus.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _textController.text.trim();
    final url = _urlController.text.trim();

    // If URL is empty or just 'https://', treat as remove link
    final effectiveUrl = url.isEmpty || url == 'https://' || url == 'http://'
        ? null
        : url;

    // Text is required if adding a new link (not removing)
    if (effectiveUrl != null && text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter display text')),
      );
      _textFocus.requestFocus();
      return;
    }

    Navigator.of(context).pop(LinkResult(text: text, url: effectiveUrl));
  }

  void _removeLink() {
    final text = _textController.text.trim();
    Navigator.of(context).pop(LinkResult(text: text, url: null));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.isEditingExisting ? 'Edit Link' : 'Add Link'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _textController,
              focusNode: _textFocus,
              autofocus: widget.initialText?.isEmpty ?? true,
              decoration: const InputDecoration(
                labelText: 'Display Text',
                hintText: 'Enter the text to display',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _urlFocus.requestFocus(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              focusNode: _urlFocus,
              autofocus: widget.initialText?.isNotEmpty ?? false,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://example.com',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.isEditingExisting)
          TextButton(
            onPressed: _removeLink,
            child: Text(
              'Remove Link',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.isEditingExisting ? 'Update' : 'Add'),
        ),
      ],
    );
  }
}
