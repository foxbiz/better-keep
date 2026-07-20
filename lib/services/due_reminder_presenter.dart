import 'package:better_keep/models/note.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

typedef MarkReminderDone = Future<bool> Function();
typedef ReminderNoteLoader = Future<Note?> Function(int noteId);

/// Presents an overdue-reminder decision while its note editor is open.
///
/// The editor owns [shownOccurrences], so dismissing the dialog suppresses that
/// occurrence only until the editor is closed. Delivery time is intentionally
/// irrelevant here: all-day reminders become overdue after their calendar day.
class DueReminderPresenter {
  DueReminderPresenter._(this._loadNote);

  static final instance = DueReminderPresenter._(Note.findById);

  @visibleForTesting
  factory DueReminderPresenter.forTesting({
    required ReminderNoteLoader loadNote,
  }) => DueReminderPresenter._(loadNote);

  final ReminderNoteLoader _loadNote;

  Future<void> showIfDue({
    required Note note,
    required Set<String> shownOccurrences,
    required MarkReminderDone onMarkDone,
    required BuildContext context,
  }) async {
    final noteId = note.id;
    if (noteId == null || !context.mounted) return;

    Note? latest;
    try {
      latest = await _loadNote(noteId);
    } catch (_) {
      return;
    }
    if (!context.mounted || latest == null || !_isOverdue(latest)) return;

    // A dialog, bottom sheet, or another route is already covering the editor.
    // Wait for a future editor resume instead of stacking another modal.
    if (ModalRoute.of(context)?.isCurrent != true) return;

    final currentNote = latest;
    final token = occurrenceToken(currentNote);
    if (!shownOccurrences.add(token)) return;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => _OverdueReminderDialog(
          note: currentNote,
          occurrenceToken: token,
          onMarkDone: () => _completeIfCurrent(
            noteId: noteId,
            token: token,
            onMarkDone: onMarkDone,
          ),
        ),
      );
    } on FlutterError {
      // The editor may have been disposed between the database read and route
      // creation. Let this occurrence be reconsidered in a future session.
      shownOccurrences.remove(token);
    }
  }

  Future<bool> _completeIfCurrent({
    required int noteId,
    required String token,
    required MarkReminderDone onMarkDone,
  }) async {
    try {
      final current = await _loadNote(noteId);
      if (!_isOverdue(current) || occurrenceToken(current!) != token) {
        return true;
      }

      if (await onMarkDone()) return true;

      final latest = await _loadNote(noteId);
      return !_isOverdue(latest) || occurrenceToken(latest!) != token;
    } catch (_) {
      // The note operation may have committed before a later scheduling or UI
      // step threw. One last read distinguishes that case from a real failure.
      try {
        final latest = await _loadNote(noteId);
        return !_isOverdue(latest) || occurrenceToken(latest!) != token;
      } catch (_) {
        return false;
      }
    }
  }

  bool _isOverdue(Note? note) {
    final reminder = note?.reminder;
    if (note == null || reminder == null || note.completed || note.trashed) {
      return false;
    }
    return reminder.isOverdueAt(DateTime.now());
  }

  String occurrenceToken(Note note) {
    final reminder = note.reminder!;
    return '${note.id}:${reminder.revision}:${reminder.dateTime.toIso8601String()}';
  }
}

class _OverdueReminderDialog extends StatefulWidget {
  const _OverdueReminderDialog({
    required this.note,
    required this.occurrenceToken,
    required this.onMarkDone,
  });

  final Note note;
  final String occurrenceToken;
  final Future<bool> Function() onMarkDone;

  @override
  State<_OverdueReminderDialog> createState() => _OverdueReminderDialogState();
}

class _OverdueReminderDialogState extends State<_OverdueReminderDialog> {
  bool _isCompleting = false;
  bool _showFailure = false;
  bool _isDismissing = false;

  @override
  void initState() {
    super.initState();
    widget.note.sub('changed', _onNoteChanged);
  }

  @override
  void dispose() {
    widget.note.unsub('changed', _onNoteChanged);
    super.dispose();
  }

  void _onNoteChanged(NoteEvent event) {
    if (!mounted || event.note.id != widget.note.id) return;
    final updated = event.note;
    final reminder = updated.reminder;
    final isSameOverdueOccurrence =
        !updated.completed &&
        !updated.trashed &&
        reminder != null &&
        reminder.isOverdueAt(DateTime.now()) &&
        DueReminderPresenter.instance.occurrenceToken(updated) ==
            widget.occurrenceToken;
    if (!isSameOverdueOccurrence) {
      _isDismissing = true;
      Navigator.of(context).pop();
    }
  }

  Future<void> _markDone() async {
    if (_isCompleting) return;
    setState(() {
      _isCompleting = true;
      _showFailure = false;
    });

    var success = false;
    try {
      success = await widget.onMarkDone();
    } catch (_) {
      success = false;
    }
    if (!mounted || _isDismissing) return;
    if (success) {
      _isDismissing = true;
      Navigator.of(context).pop();
      return;
    }

    setState(() {
      _isCompleting = false;
      _showFailure = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: !_isCompleting,
      child: AlertDialog(
        title: Text(context.l10n.overdueReminderTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.overdueReminderMessage),
            if (_showFailure) ...[
              const SizedBox(height: 12),
              Text(
                context.l10n.markReminderDoneFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _isCompleting ? null : () => Navigator.of(context).pop(),
            child: Text(context.l10n.notNow),
          ),
          TextButton(
            onPressed: _isCompleting ? null : _markDone,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isCompleting) ...[
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(context.l10n.markAsDone),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
