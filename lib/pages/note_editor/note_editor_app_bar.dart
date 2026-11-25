import 'package:better_keep/services/iphone_duo.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

/// Shared app-bar chrome for the normal and focused note editors.
class NoteEditorAppBar extends StatelessWidget implements PreferredSizeWidget {
  const NoteEditorAppBar({
    super.key,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.leading,
    this.leadingWidth,
    this.title,
    this.actions,
  });

  final Color backgroundColor;
  final Color foregroundColor;
  final Widget leading;
  final double? leadingWidth;
  final Widget? title;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      iconTheme: IconThemeData(color: foregroundColor),
      actionsIconTheme: IconThemeData(color: foregroundColor),
      leadingWidth: leadingWidth,
      leading: leading,
      title: title,
      centerTitle: true,
      actions: actions,
    );
  }
}

/// The responsive checked/total title shared by both editor modes.
class NoteCheckboxProgressTitle extends StatelessWidget {
  const NoteCheckboxProgressTitle({
    super.key,
    required this.checked,
    required this.total,
    required this.backgroundColor,
    required this.foregroundColor,
    this.onTap,
    this.tooltip,
  });

  final int checked;
  final int total;
  final Color backgroundColor;
  final Color foregroundColor;
  final VoidCallback? onTap;
  final String? tooltip;

  /// The width this title needs. An iPhone Duo keeps the icon and padding, and
  /// moves actions out of the way instead. Other devices can drop the icon.
  static double requiredWidth(
    BuildContext context, {
    required int checked,
    required int total,
    required bool withIcon,
    TextStyle? style,
  }) {
    if (total == 0) return 0;
    final painter = TextPainter(
      text: TextSpan(
        text: '$checked/$total',
        style: (style ?? DefaultTextStyle.of(context).style).merge(_textStyle),
      ),
      textDirection: Directionality.of(context),
      // An app bar limits how far its title grows.
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.34),
      maxLines: 1,
    )..layout();
    final text = painter.width;
    painter.dispose();
    return (text + (withIcon ? 18 + 4 + 2 * 10 : 2 * 8)).ceilToDouble();
  }

  static const _textStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
  );

  @override
  Widget build(BuildContext context) {
    if (total == 0) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) => _buildTitle(
        context,
        compact:
            (!isIPhoneDuo && MediaQuery.sizeOf(context).width < 400) ||
            constraints.maxWidth <
                requiredWidth(
                  context,
                  checked: checked,
                  total: total,
                  withIcon: true,
                ),
      ),
    );
  }

  Widget _buildTitle(BuildContext context, {required bool compact}) {
    final isComplete = checked == total;
    final completeColor = visibleOn(
      backgroundColor,
      Colors.green,
      fallback: foregroundColor,
      minContrast: 4.5,
    );
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (!compact) ...[
          Icon(
            isComplete ? Icons.check_circle : Icons.checklist,
            size: 18,
            color: isComplete ? completeColor : foregroundColor.withAlpha(180),
          ),
          const SizedBox(width: 4),
        ],
        Text(
          '$checked/$total',
          style: _textStyle.copyWith(
            color: isComplete ? completeColor : foregroundColor,
          ),
        ),
      ],
    );
    if (onTap == null) {
      return Semantics(
        key: const ValueKey('note_checkbox_progress_title'),
        label: '$checked/$total',
        child: content,
      );
    }
    final message = tooltip ?? context.l10n.openChecklistView;
    return Tooltip(
      message: message,
      child: Semantics(
        button: true,
        label: '$message, $checked/$total',
        child: InkWell(
          key: const ValueKey('note_checkbox_progress_title'),
          onTap: onTap,
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
              child: Center(
                child: FittedBox(fit: BoxFit.scaleDown, child: content),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Actions that can move from the app bar into its menu, first to go first.
enum NoteEditorMenuAction { color, labels, pin, reminder }

/// Shared note-level app-bar actions used by every note editing surface.
class NoteEditorAppBarActions extends StatelessWidget {
  const NoteEditorAppBarActions({
    super.key,
    required this.note,
    required this.foregroundColor,
    required this.onSearch,
    required this.onColor,
    required this.onReminder,
    required this.onPin,
    required this.onLabels,
    required this.overflowMenu,
    this.inMenu = const {},
  });

  /// The actions that must move into the menu for a title [titleWidth] wide to
  /// fit an app bar of [width], which excludes the system insets.
  static Set<NoteEditorMenuAction> actionsInMenu({
    required double width,
    required double leadingWidth,
    required double titleWidth,
    required bool alwaysMoveColor,
  }) {
    final room =
        width -
        leadingWidth -
        titleWidth -
        2 * NavigationToolbar.kMiddleSpacing -
        // Search and the menu itself.
        2 * kMinInteractiveDimension;
    const movable = NoteEditorMenuAction.values;
    final fitting = (room / kMinInteractiveDimension).floor().clamp(
      0,
      movable.length,
    );
    return {
      if (alwaysMoveColor) NoteEditorMenuAction.color,
      ...movable.take(movable.length - fitting),
    };
  }

  final Note note;
  final Color foregroundColor;
  final VoidCallback onSearch;
  final VoidCallback onColor;
  final VoidCallback onReminder;
  final VoidCallback onPin;
  final VoidCallback onLabels;
  final Widget overflowMenu;
  final Set<NoteEditorMenuAction> inMenu;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('note_editor_search_action'),
          icon: const Icon(Icons.search),
          color: foregroundColor,
          tooltip: context.l10n.findInNote,
          onPressed: onSearch,
        ),
        if (!inMenu.contains(NoteEditorMenuAction.color))
          IconButton(
            key: const ValueKey('note_editor_color_action'),
            icon: const Icon(Icons.color_lens),
            color: foregroundColor,
            tooltip: context.l10n.pickNoteColor,
            onPressed: onColor,
          ),
        if (!inMenu.contains(NoteEditorMenuAction.reminder))
          IconButton(
            key: const ValueKey('note_editor_reminder_action'),
            color: foregroundColor,
            onPressed: onReminder,
            icon: Icon(reminderIcon(note)),
            tooltip: context.l10n.reminder,
          ),
        if (!inMenu.contains(NoteEditorMenuAction.pin))
          IconButton(
            key: const ValueKey('note_editor_pin_action'),
            color: foregroundColor,
            onPressed: onPin,
            icon: Icon(note.pinned ? Icons.push_pin : Icons.push_pin_outlined),
          ),
        if (!inMenu.contains(NoteEditorMenuAction.labels))
          IconButton(
            key: const ValueKey('note_editor_labels_action'),
            color: foregroundColor,
            onPressed: onLabels,
            icon: Icon(
              note.labels != null && note.labels!.isNotEmpty
                  ? Icons.label
                  : Icons.label_outline,
            ),
            tooltip: context.l10n.labels,
          ),
        overflowMenu,
      ],
    );
  }

  static IconData reminderIcon(Note note) {
    if (!note.hasReminder) return Icons.notifications_none;
    final isAlarm = note.reminder?.type == ReminderType.alarm;
    if (note.completed) {
      return isAlarm ? Icons.alarm_off : Icons.notifications_off;
    }
    if (note.hasReminderExpired) {
      return isAlarm ? Icons.alarm_on : Icons.notification_important;
    }
    return isAlarm ? Icons.alarm : Icons.notifications_active;
  }
}

/// Shared overflow menu chrome. Callers own persistence and route outcomes.
class NoteEditorOverflowMenu extends StatelessWidget {
  const NoteEditorOverflowMenu({
    super.key,
    required this.note,
    required this.onArchivedChanged,
    required this.onReadOnlyChanged,
    required this.onLockedChanged,
    required this.onShare,
    required this.onDuplicate,
    required this.onDelete,
    this.lockBusy = false,
    this.onSaveAs,
    this.onCopyAs,
    this.onPasteAs,
    this.onConvertChecklist,
    this.onColor,
    this.onLabels,
    this.onReminder,
    this.onPin,
  });

  final Note note;
  final ValueChanged<bool> onArchivedChanged;
  final ValueChanged<bool> onReadOnlyChanged;
  final ValueChanged<bool> onLockedChanged;
  final VoidCallback onShare;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final bool lockBusy;
  final VoidCallback? onSaveAs;
  final VoidCallback? onCopyAs;
  final VoidCallback? onPasteAs;
  final VoidCallback? onConvertChecklist;
  final VoidCallback? onColor;
  final VoidCallback? onLabels;
  final VoidCallback? onReminder;
  final VoidCallback? onPin;

  @override
  Widget build(BuildContext context) {
    final isSaved = note.id != null;
    return PopupMenuButton<void>(
      key: const ValueKey('note_editor_overflow_menu'),
      itemBuilder: (menuContext) => [
        if (onColor != null)
          PopupMenuItem<void>(
            key: const ValueKey('note_editor_overflow_color_action'),
            height: 20,
            onTap: onColor,
            child: ListTile(
              leading: const Icon(Icons.color_lens),
              title: Text(context.l10n.pickNoteColor),
            ),
          ),
        if (onLabels != null)
          PopupMenuItem<void>(
            key: const ValueKey('note_editor_overflow_labels_action'),
            height: 20,
            onTap: onLabels,
            child: ListTile(
              leading: Icon(
                note.labels != null && note.labels!.isNotEmpty
                    ? Icons.label
                    : Icons.label_outline,
              ),
              title: Text(context.l10n.labels),
            ),
          ),
        if (onReminder != null)
          PopupMenuItem<void>(
            key: const ValueKey('note_editor_overflow_reminder_action'),
            height: 20,
            onTap: onReminder,
            child: ListTile(
              leading: Icon(NoteEditorAppBarActions.reminderIcon(note)),
              title: Text(context.l10n.reminder),
            ),
          ),
        if (onPin != null)
          PopupMenuItem<void>(
            key: const ValueKey('note_editor_overflow_pin_action'),
            height: 20,
            child: CheckboxListTile(
              value: note.pinned,
              onChanged: (_) {
                Navigator.of(menuContext).pop();
                onPin!();
              },
              title: Text(context.l10n.pinnedNotes),
            ),
          ),
        PopupMenuItem<void>(
          height: 20,
          child: CheckboxListTile(
            value: note.archived,
            onChanged: (checked) {
              Navigator.of(menuContext).pop();
              onArchivedChanged(checked ?? false);
            },
            title: Text(context.l10n.archive),
          ),
        ),
        PopupMenuItem<void>(
          height: 20,
          child: CheckboxListTile(
            value: note.readOnly,
            onChanged: (checked) {
              Navigator.of(menuContext).pop();
              onReadOnlyChanged(checked ?? false);
            },
            title: Text(context.l10n.readOnly),
          ),
        ),
        PopupMenuItem<void>(
          height: 20,
          child: CheckboxListTile(
            value: note.locked,
            onChanged: lockBusy
                ? null
                : (checked) {
                    Navigator.of(menuContext).pop();
                    onLockedChanged(checked ?? false);
                  },
            title: Row(
              children: [
                Expanded(child: Text(context.l10n.locked)),
                if (lockBusy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ),
        if (onConvertChecklist != null)
          PopupMenuItem<void>(
            key: const ValueKey('convert_entire_checklist_action'),
            height: 20,
            onTap: onConvertChecklist,
            child: ListTile(
              leading: const Icon(Icons.format_list_bulleted),
              title: Text(context.l10n.convertEntireChecklistToText),
            ),
          ),
        const PopupMenuDivider(),
        if (onSaveAs != null)
          PopupMenuItem<void>(
            height: 20,
            onTap: onSaveAs,
            child: ListTile(
              leading: const Icon(Icons.save_alt),
              title: Text(context.l10n.saveAs),
            ),
          ),
        if (onCopyAs != null)
          PopupMenuItem<void>(
            height: 20,
            onTap: onCopyAs,
            child: ListTile(
              leading: const Icon(Icons.content_copy),
              title: Text(context.l10n.copyAs),
            ),
          ),
        if (onPasteAs != null)
          PopupMenuItem<void>(
            height: 20,
            onTap: onPasteAs,
            child: ListTile(
              leading: const Icon(Icons.paste),
              title: Text(context.l10n.pasteAs),
            ),
          ),
        PopupMenuItem<void>(
          height: 20,
          onTap: onShare,
          child: ListTile(
            leading: const Icon(Icons.share),
            title: Text(context.l10n.share),
          ),
        ),
        PopupMenuItem<void>(
          height: 20,
          enabled: isSaved,
          onTap: isSaved ? onDuplicate : null,
          child: ListTile(
            enabled: isSaved,
            leading: const Icon(Icons.copy),
            title: Text(context.l10n.duplicate),
          ),
        ),
        PopupMenuItem<void>(
          height: 20,
          enabled: isSaved,
          onTap: isSaved ? onDelete : null,
          child: ListTile(
            enabled: isSaved,
            leading: const Icon(Icons.delete),
            title: Text(context.l10n.delete),
          ),
        ),
      ],
    );
  }
}
