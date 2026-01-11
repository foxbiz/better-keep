import 'package:flutter/material.dart';

/// Shows a confirmation dialog for cascading checkbox changes
/// Returns true if user confirms, false if cancelled
Future<bool> showCheckboxCascadeDialog(
  BuildContext context, {
  required bool isChecking,
  required int affectedCount,
}) async {
  final action = isChecking ? 'check' : 'uncheck';
  final items = affectedCount == 1 ? 'item' : 'items';

  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        icon: Icon(
          isChecking ? Icons.check_box : Icons.check_box_outline_blank,
          size: 40,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text('${isChecking ? 'Check' : 'Uncheck'} nested items?'),
        content: Text('This will $action $affectedCount nested $items.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(isChecking ? 'Check All' : 'Uncheck All'),
          ),
        ],
      );
    },
  );

  return result ?? false;
}
