import 'package:better_keep/dialogs/prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

class LinkButton extends StatefulWidget {
  final QuillController controller;
  final bool isEditingTitle;
  final bool readOnly;

  const LinkButton({
    super.key,
    required this.readOnly,
    required this.controller,
    required this.isEditingTitle,
  });

  @override
  State<LinkButton> createState() => _LinkButtonState();
}

class _LinkButtonState extends State<LinkButton> {
  bool isLink = false;
  bool hasSelection = false;

  void _didChangeSelection() {
    setState(() {
      isLink = QuillTextLink.isSelected(widget.controller);
      hasSelection =
          !widget.controller.selection.isCollapsed ||
          QuillTextLink.prepare(widget.controller).text.isNotEmpty;
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
    return IconButton(
      isSelected: isLink,
      icon: Icon(Icons.link),
      onPressed: hasSelection && !widget.isEditingTitle && !widget.readOnly
          ? () async {
              final prep = QuillTextLink.prepare(widget.controller);
              final link = await prompt(
                context,
                type: PromptType.url,
                title: 'Add Link for ${prep.text}',
                message: 'Enter the URL to link to:',
                placeholder: 'https://example.com',
                currentText: prep.link ?? '',
              );

              if (link == null) {
                return;
              }

              final textLink = QuillTextLink(
                prep.text,
                link.isEmpty ? null : link,
              );
              textLink.submit(widget.controller);
            }
          : null,
    );
  }
}
