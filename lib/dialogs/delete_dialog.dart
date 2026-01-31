import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

Future<bool?> showDeleteDialog(
  BuildContext context, {
  String? title,
  String? message,
  bool isPermanent = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final l10n = context.l10n;
      final displayTitle = title ?? l10n.deleteQuestion;
      final displayMessage = message ?? l10n.actionCannotBeUndone;
      return AlertDialog(
        icon: isPermanent
            ? const Icon(Icons.delete_forever, color: Colors.red, size: 40)
            : null,
        title: Text(displayTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(displayMessage),
            if (isPermanent) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.permanentDeleteWarning,
                        style: const TextStyle(color: Colors.red, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              isPermanent ? l10n.deleteForever : l10n.delete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      );
    },
  );
}
