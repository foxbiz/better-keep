import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/attachments/attachment.dart';
import 'package:better_keep/pages/image_viewer.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/ui/show_page.dart';
import 'package:flutter/material.dart';

class NoteAttachmentsCarousel extends StatefulWidget {
  final Note note;
  final double height;
  final void Function()? onPop;

  const NoteAttachmentsCarousel({
    super.key,
    this.onPop,
    this.height = 250,
    required this.note,
  });

  @override
  State<NoteAttachmentsCarousel> createState() =>
      _NoteAttachmentsCarouselState();
}

class _NoteAttachmentsCarouselState extends State<NoteAttachmentsCarousel> {
  late List<Attachment> _cachedAttachments;

  @override
  void initState() {
    super.initState();
    _cachedAttachments = List.from(widget.note.attachments);
    widget.note.sub("changed", _noteChangeListener);
  }

  @override
  void dispose() {
    widget.note.unsub("changed", _noteChangeListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Filter to only visual attachments (images and sketches)
    final visualAttachments = widget.note.attachments.where((attachment) {
      return attachment.type == AttachmentType.image ||
          attachment.type == AttachmentType.sketch;
    }).toList();

    final totalCount = visualAttachments.length;

    if (totalCount == 0) return const SizedBox.shrink();

    return SizedBox(
      height: widget.height,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: totalCount,
        itemBuilder: (context, index) {
          final attachment = visualAttachments[index];
          final isImage = attachment.type == AttachmentType.image;

          if (isImage) {
            final image = attachment.image!;
            final heroTag = image.path;
            return Padding(
              padding: EdgeInsets.only(
                left: index == 0 ? 8 : 8,
                right: index == totalCount - 1 ? 8 : 0,
                top: 8,
                bottom: 8,
              ),
              child: GestureDetector(
                onTap: () async {
                  await showPage(
                    context,
                    ImageViewer(
                      note: widget.note,
                      image: image,
                      attachment: attachment,
                      heroTag: heroTag,
                    ),
                  );

                  if (widget.onPop != null) {
                    widget.onPop!();
                  }
                },
                child: Hero(
                  tag: heroTag,
                  child: AspectRatio(
                    aspectRatio: image.aspectRatio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: UniversalImage(
                        path: image.path,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
            );
          } else {
            final sketch = attachment.sketch!;
            final sketchIndex = widget.note.sketches.indexOf(sketch);
            return Padding(
              padding: EdgeInsets.only(
                left: index == 0 ? 8 : 8,
                right: index == totalCount - 1 ? 8 : 0,
                top: 8,
                bottom: 8,
              ),
              child: GestureDetector(
                onTap: () async {
                  await showPage(
                    context,
                    SketchPage(
                      note: widget.note,
                      sketch: sketch,
                      heroTag: sketch.previewPath,
                      initialIndex: sketchIndex >= 0 ? sketchIndex : null,
                    ),
                  );

                  if (widget.onPop != null) {
                    widget.onPop!();
                  }
                },
                child: Hero(
                  tag: sketch.previewPath,
                  child: AspectRatio(
                    aspectRatio: sketch.aspectRatio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: UniversalImage(
                        path: sketch.previewPath,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
        },
      ),
    );
  }

  void _noteChangeListener(dynamic _) {
    if (_attachmentsChanged()) {
      _cachedAttachments = List.from(widget.note.attachments);
      setState(() {});
    }
  }

  bool _attachmentsChanged() {
    final current = widget.note.attachments;
    if (current.length != _cachedAttachments.length) return true;

    for (int i = 0; i < current.length; i++) {
      final a = current[i];
      final b = _cachedAttachments[i];
      if (a.type != b.type) return true;

      switch (a.type) {
        case AttachmentType.image:
          if (a.image?.path != b.image?.path) return true;
        case AttachmentType.sketch:
          if (a.sketch?.previewPath != b.sketch?.previewPath ||
              a.sketch?.backgroundImage != b.sketch?.backgroundImage) {
            return true;
          }
        case AttachmentType.audio:
          if (a.recording?.id != b.recording?.id) return true;
      }
    }
    return false;
  }
}
