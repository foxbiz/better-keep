import 'package:better_keep/services/note_table_codec.dart';
import 'package:flutter_quill/flutter_quill.dart';

abstract final class NoteDocumentProjection {
  static const String objectReplacementCharacter = '\uFFFC';

  static String toPlainText(Document document) =>
      operationsToPlainText(document.toDelta().toJson());

  static String operationsToPlainText(List<dynamic> operations) {
    final buffer = StringBuffer();
    for (final operation in operations) {
      if (operation is! Map) continue;
      final insert = operation['insert'];
      if (insert is String) {
        buffer.write(insert);
        continue;
      }
      final table = NoteTableCodec.tryDecodeInsert(insert);
      if (table != null) {
        buffer.write(table.toPlainText());
      } else if (insert != null) {
        buffer.write(objectReplacementCharacter);
      }
    }
    return buffer.toString();
  }
}
