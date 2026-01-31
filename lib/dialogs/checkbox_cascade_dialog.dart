import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

/// Shows a confirmation dialog for cascading checkbox changes
/// Returns true if user confirms, false if cancelled
Future<bool> showCheckboxCascadeDialog(
  BuildContext context, {
  required bool isChecking,
  required int affectedCount,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      return AlertDialog(
        icon: Icon(
          isChecking ? Icons.check_box : Icons.check_box_outline_blank,
          size: 40,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(
          isChecking
              ? context.l10n.checkNestedItems
              : context.l10n.uncheckNestedItems,
        ),
        content: Text(
          isChecking
              ? context.l10n.checkNestedItemsCount(affectedCount)
              : context.l10n.uncheckNestedItemsCount(affectedCount),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              isChecking ? context.l10n.checkAll : context.l10n.uncheckAll,
            ),
          ),
        ],
      );
    },
  );

  return result ?? false;
}
