import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/note_editor/embeds/note_attachment_embed.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_editing.dart';
import 'package:better_keep/pages/note_editor/embeds/note_table_embed.dart';
import 'package:better_keep/utils/quill_image_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';

List<EmbedBuilder> noteEmbedBuilders({
  required Note note,
  NoteEmbedEditing? editing,
  double inlineWidth = 640,
  double? mediaMaxHeight,
  double? tablePreviewMaxHeight,
  bool includeTables = true,
}) => [
  if (includeTables)
    NoteTableEmbedBuilder(
      note: note,
      editing: editing,
      previewMaxHeight: tablePreviewMaxHeight,
    ),
  NoteAttachmentEmbedBuilder(
    note,
    inlineWidth: inlineWidth,
    mediaMaxHeight: mediaMaxHeight,
    editing: editing,
  ),
  ...kIsWeb
      ? FlutterQuillEmbeds.editorWebBuilders()
      : FlutterQuillEmbeds.editorBuilders(
          imageEmbedConfig: QuillEditorImageEmbedConfig(
            imageProviderBuilder: buildQuillImageProvider,
            imageErrorWidgetBuilder: buildQuillImageErrorWidget,
          ),
        ),
];
