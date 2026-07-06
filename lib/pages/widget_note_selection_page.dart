import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/widget_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class WidgetNoteSelectionPage extends StatefulWidget {
  final int? widgetId;
  final int? iosSlot;

  const WidgetNoteSelectionPage({super.key, this.widgetId, this.iosSlot});

  @override
  State<WidgetNoteSelectionPage> createState() =>
      _WidgetNoteSelectionPageState();
}

class _WidgetNoteSelectionPageState extends State<WidgetNoteSelectionPage> {
  late final Future<List<Note>> _notesFuture = _loadNotes();

  Future<List<Note>> _loadNotes() async {
    final notes = await Note.get(NoteType.all);
    return notes.where((note) => !note.trashed && !note.archived).toList()
      ..sort((a, b) {
        if (a.pinned && !b.pinned) return -1;
        if (!a.pinned && b.pinned) return 1;
        return (b.updatedAt ?? DateTime(0)).compareTo(
          a.updatedAt ?? DateTime(0),
        );
      });
  }

  Future<void> _selectNote(Note note) async {
    final noteId = note.id;
    if (noteId == null) {
      snackbar('This note cannot be used for a widget yet.', Colors.orange);
      return;
    }

    await WidgetService.instance.setNoteWidget(
      noteId,
      widgetId: widget.widgetId,
      iosSlot: widget.iosSlot,
    );
    if (!mounted) return;

    snackbar('Note selected for widget.', Colors.green);
    if (defaultTargetPlatform == TargetPlatform.android) {
      await SystemNavigator.pop();
    } else {
      if (!mounted) return;
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select note for widget')),
      body: FutureBuilder<List<Note>>(
        future: _notesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final notes = snapshot.data ?? [];
          if (notes.isEmpty) {
            return const Center(child: Text('No notes available'));
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: notes.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final note = notes[index];
              return ListTile(
                leading: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: note.color == Colors.transparent
                        ? Theme.of(context).colorScheme.surfaceContainerHighest
                        : note.color,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                title: Text(
                  note.title?.isNotEmpty == true ? note.title! : 'Untitled',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  note.locked ? 'Locked note' : note.plainText ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _selectNote(note),
              );
            },
          );
        },
      ),
    );
  }
}
