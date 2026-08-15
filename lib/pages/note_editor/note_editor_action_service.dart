import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';

/// Note-level operations that must behave identically across editor routes.
abstract final class NoteEditorActionService {
  static Future<Note> duplicate(Note source) async {
    final duplicate = Note(
      title: source.title,
      content: source.content,
      plainText: source.plainText,
      labels: source.labels,
      color: source.color,
      pinned: source.pinned,
      archived: source.archived,
      locked: false,
      readOnly: source.readOnly,
      attachments: source.attachments
          .map((attachment) => NoteAttachment.fromJson(attachment.toJson()))
          .toList(),
    );
    final password = source.password;
    if (source.locked) {
      if (password == null || password.isEmpty) {
        throw const NoteLockException(
          'A locked note must be unlocked before it can be duplicated',
        );
      }
      await duplicate.lock(password);
    } else if (await duplicate.save() < 0) {
      throw StateError('The duplicate note could not be saved');
    }
    return duplicate;
  }
}
