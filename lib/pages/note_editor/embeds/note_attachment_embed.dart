import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_editing.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/note_embed_rules.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:uuid/uuid.dart';

const noteAttachmentEmbedType = 'note-attachment';

Map<String, dynamic> attachmentReference(
  NoteAttachment attachment, {
  bool inline = false,
}) {
  attachment.id ??= const Uuid().v4();
  return {
    'id': const Uuid().v4(),
    'src': 'attachment://${attachment.id}',
    'placement': inline ? 'inline' : 'block',
  };
}

NoteAttachment? resolveNoteAttachment(Note note, String src) {
  if (!src.startsWith('attachment://')) return null;
  final id = src.substring('attachment://'.length);
  for (final attachment in note.attachments) {
    if (attachment.id == id) return attachment;
  }
  return null;
}

class NoteAttachmentEmbedBuilder extends EmbedBuilder {
  const NoteAttachmentEmbedBuilder(
    this.note, {
    this.inlineWidth = 128,
    this.mediaMaxHeight,
    this.editing,
  });
  final double inlineWidth;
  final double? mediaMaxHeight;
  final NoteEmbedEditing? editing;
  final Note note;
  @override
  String get key => noteAttachmentEmbedType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final data = Map<String, dynamic>.from(embedContext.node.value.data as Map);
    final offset = embedContext.node.documentOffset;
    final inline = data['placement'] == 'inline';
    final attachment = resolveNoteAttachment(note, data['src'] as String);
    final image = attachment?.image;
    final sketch = attachment?.sketch;
    final path = image?.src ?? sketch?.previewImage;
    final ratio = image?.ratio ?? sketch?.aspectRatio ?? 1.0;
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: path == null || (note.locked && !note.unlocked)
          ? ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Center(
                child: Tooltip(
                  message: context.l10n.inlineAttachmentUnavailable,
                  child: const Icon(Icons.image_not_supported_outlined),
                ),
              ),
            )
          : UniversalImage(
              key: ValueKey(
                '$path:${image?.lastModified}:${sketch?.strokesContentHash}:${sketch?.blurredThumbnail}',
              ),
              path: path,
              fit: BoxFit.contain,
              passwordProtectedDecoder: note.locked && note.unlocked
                  ? note.decryptAttachmentForSession
                  : null,
            ),
    );
    Widget frame(double available) {
      var width = inline
          ? available.clamp(40.0, 128.0)
          : available.clamp(40.0, 640.0);
      var height = (width / (ratio > 0 && ratio.isFinite ? ratio : 1)).clamp(
        40.0,
        inline ? 100.0 : 400.0,
      );
      if (mediaMaxHeight != null && height > mediaMaxHeight!) {
        width *= mediaMaxHeight! / height;
        height = mediaMaxHeight!;
      }
      final imageWidget = SizedBox(
        width: width,
        height: height,
        child: content,
      );
      if (embedContext.readOnly || editing == null) return imageWidget;
      return Semantics(
        label: context.l10n.inNoteImage,
        child: NoteEmbedGestureRegion(
          editing: editing!,
          owner: embedContext.controller,
          child: PopupMenuButton<String>(
            tooltip: context.l10n.imagePlacement,
            onSelected: (action) {
              if (action == 'remove') {
                replaceNoteEmbed(
                  embedContext.controller,
                  key,
                  data['id'] as String,
                  null,
                  offsetHint: offset,
                );
              } else {
                changeAttachmentPlacement(
                  embedContext.controller,
                  data,
                  inline: action == 'inline',
                  offsetHint: offset,
                );
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'inline',
                checked: inline,
                child: Text(context.l10n.imageInline),
              ),
              CheckedPopupMenuItem(
                value: 'block',
                checked: !inline,
                child: Text(context.l10n.imageNewLine),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'remove',
                child: Text(context.l10n.removeImageReference),
              ),
            ],
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: inline ? 3 : 0,
                vertical: 4,
              ),
              child: imageWidget,
            ),
          ),
        ),
      );
    }

    // Inline spans have unbounded width; a block receives its actual cell/editor width.
    if (embedContext.inline || inline) return frame(inlineWidth - 6);
    return LayoutBuilder(
      builder: (_, constraints) => Align(
        alignment: Alignment.centerLeft,
        child: frame(constraints.maxWidth),
      ),
    );
  }
}

void changeAttachmentPlacement(
  QuillController controller,
  Map<String, dynamic> data, {
  required bool inline,
  int? offsetHint,
}) {
  if (controller.readOnly || (data['placement'] == 'inline') == inline) return;
  final offset = noteEmbedOffset(
    controller,
    noteAttachmentEmbedType,
    data['id'] as String,
    offsetHint: offsetHint,
  );
  if (offset == null) return;
  final plain = controller.document.toPlainText();
  final beforeBreak = offset > 0 && plain[offset - 1] == '\n';
  final afterBreak = offset + 1 < plain.length - 1 && plain[offset + 1] == '\n';
  bool canJoin(int position) {
    final line = controller.document.queryChild(position).node;
    return line is Line &&
        !line.children.any(
          (child) => child is Embed && isNoteBlock(child.value.toJson()),
        );
  }

  final joinBefore = inline && beforeBreak && canJoin(offset - 1);
  final joinAfter = inline && afterBreak && canJoin(offset + 2);
  final start = joinBefore ? offset - 1 : offset;
  final delta = Delta()..retain(start);
  if (!inline && offset > 0 && !beforeBreak) delta.insert('\n');
  delta.insert({
    noteAttachmentEmbedType: {
      ...data,
      'placement': inline ? 'inline' : 'block',
    },
  });
  if (!inline && offset + 1 < plain.length && plain[offset + 1] != '\n') {
    delta.insert('\n');
  }
  delta.delete(1 + (joinBefore ? 1 : 0) + (joinAfter ? 1 : 0));
  final selection = TextSelection.collapsed(offset: start + 1);
  controller.compose(delta, selection, ChangeSource.local);
  controller.updateSelection(selection, ChangeSource.local);
}

Future<NoteAttachment?> showNoteAttachmentPicker(
  BuildContext context,
  Note note,
) => showDialog<NoteAttachment>(
  context: context,
  builder: (context) {
    final attachments = note.attachments
        .where((a) => a.type != AttachmentType.audio)
        .toList();
    return AlertDialog(
      title: Text(context.l10n.chooseAttachment),
      content: SizedBox(
        width: 420,
        height: 320,
        child: attachments.isEmpty
            ? Center(child: Text(context.l10n.noVisualAttachments))
            : GridView.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 140,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                ),
                itemCount: attachments.length,
                itemBuilder: (context, index) {
                  final attachment = attachments[index];
                  final path =
                      attachment.image?.src ?? attachment.sketch?.previewImage;
                  return Tooltip(
                    message: attachment.type == AttachmentType.sketch
                        ? context.l10n.sketch
                        : context.l10n.image,
                    child: Material(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.pop(context, attachment),
                        child: path == null
                            ? const Icon(Icons.draw_outlined)
                            : IgnorePointer(
                                child: UniversalImage(
                                  path: path,
                                  fit: BoxFit.cover,
                                  passwordProtectedDecoder:
                                      note.locked && note.unlocked
                                      ? note.decryptAttachmentForSession
                                      : null,
                                ),
                              ),
                      ),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
      ],
    );
  },
);
