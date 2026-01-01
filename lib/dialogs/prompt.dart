import 'package:flutter/material.dart';

enum PromptType { text, password, number, email, url }

Future<String?> prompt(
  BuildContext context, {
  String title = 'Prompt',
  String? message,
  String? placeholder,
  String? currentText,
  bool confirm = false,
  PromptType type = PromptType.text,
}) {
  return showDialog<String?>(
    context: context,
    builder: (context) {
      return Prompt(
        title: title,
        message: message,
        placeholder: placeholder,
        defaultText: currentText,
        confirm: confirm,
        type: type,
      );
    },
  );
}

class Prompt extends StatefulWidget {
  final String title;
  final String? message;
  final String? placeholder;
  final String? defaultText;
  final bool confirm;
  final PromptType type;
  const Prompt({
    super.key,
    required this.title,
    this.message,
    this.placeholder,
    this.defaultText,
    this.confirm = false,
    required this.type,
  });

  @override
  State<Prompt> createState() => _PromptState();
}

class _PromptState extends State<Prompt> {
  String? hasError;
  late final TextEditingController inputController;
  late final TextEditingController confirmController;

  @override
  void initState() {
    inputController = TextEditingController(text: widget.defaultText);
    confirmController = TextEditingController();
    super.initState();
  }

  @override
  void dispose() {
    inputController.dispose();
    confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextInputType inputType = switch (widget.type) {
      PromptType.number => TextInputType.number,
      PromptType.email => TextInputType.emailAddress,
      PromptType.url => TextInputType.url,
      _ => TextInputType.text,
    };

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null && widget.message!.isNotEmpty)
            Text(widget.message!),
          TextField(
            autofocus: true,
            autocorrect: true,
            keyboardType: inputType,
            obscureText: widget.type == PromptType.password,
            onSubmitted: widget.confirm
                ? null
                : (text) => Navigator.pop(context, text),
            controller: inputController,
            decoration: InputDecoration(hintText: widget.placeholder ?? ''),
            textInputAction: TextInputAction.done,
          ),
          if (widget.confirm)
            TextField(
              autofocus: true,
              autocorrect: true,
              obscureText: widget.type == PromptType.password,
              onSubmitted: (_) => _submit(),
              controller: confirmController,
              decoration: InputDecoration(
                hintText: 'Confirm ${widget.placeholder}',
              ),
              textInputAction: TextInputAction.done,
            ),

          if (hasError != null && hasError!.isNotEmpty)
            Text(hasError!, style: TextStyle(color: Colors.red[400])),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text('Cancel'),
        ),
        TextButton(onPressed: _submit, child: Text('OK')),
      ],
    );
  }

  void _submit() {
    if (widget.confirm && inputController.text != confirmController.text) {
      setState(() {
        hasError = "Not matched";
      });
      return;
    }

    Navigator.pop(context, inputController.text);
  }
}
