import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/pages/image_viewer.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';

class NoteAttachmentsCarousel extends StatefulWidget {
  final double height;
  final Note note;
  final void Function()? onPop;
  final ScrollController? scrollController;

  const NoteAttachmentsCarousel({
    super.key,
    this.onPop,
    this.height = 250,
    required this.note,
    this.scrollController,
  });

  @override
  State<NoteAttachmentsCarousel> createState() =>
      _NoteAttachmentsCarouselState();
}

class _NoteAttachmentsCarouselState extends State<NoteAttachmentsCarousel> {
  late List<NoteAttachment> _cachedAttachments;

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
  void didUpdateWidget(NoteAttachmentsCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When parent rebuilds (e.g., returning from SketchPage), check if attachments changed
    if (_attachmentsChanged()) {
      _cachedAttachments = List.from(widget.note.attachments);
    }
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
        controller: widget.scrollController,
        scrollDirection: Axis.horizontal,
        itemCount: totalCount,
        itemBuilder: (context, index) {
          final attachment = visualAttachments[index];
          final isImage = attachment.type == AttachmentType.image;

          if (isImage) {
            final image = attachment.image!;
            final heroTag = 'image_${widget.note.id}_${image.src}';
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
                    aspectRatio: image.ratio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: UniversalImage(
                        path: image.src,
                        fit: BoxFit.cover,
                        passwordProtectedDecoder:
                            widget.note.locked && widget.note.unlocked
                            ? widget.note.decryptAttachmentForSession
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            );
          } else {
            final sketch = attachment.sketch!;
            final sketchIndex = widget.note.sketches.indexOf(sketch);
            final heroTag = sketch.previewImage != null
                ? 'sketch_${widget.note.id}_${sketch.previewImage}'
                : null;
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
                      heroTag: heroTag,
                      initialIndex: sketchIndex >= 0 ? sketchIndex : null,
                    ),
                    allowFullScreen: true,
                  );

                  if (widget.onPop != null) {
                    widget.onPop!();
                  }
                },
                child: sketch.previewImage != null
                    ? Hero(
                        tag: heroTag!,
                        child: AspectRatio(
                          aspectRatio: sketch.aspectRatio > 0
                              ? sketch.aspectRatio
                              : 1.0,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: UniversalImage(
                              // Use blurredThumbnail hash as key to force reload when sketch content changes
                              key: ValueKey(
                                '${sketch.previewImage}_${sketch.blurredThumbnail?.hashCode ?? 0}',
                              ),
                              path: sketch.previewImage!,
                              fit: BoxFit.contain,
                              passwordProtectedDecoder:
                                  widget.note.locked && widget.note.unlocked
                                  ? widget.note.decryptAttachmentForSession
                                  : null,
                            ),
                          ),
                        ),
                      )
                    : AspectRatio(
                        aspectRatio: sketch.aspectRatio > 0
                            ? sketch.aspectRatio
                            : 1.0,
                        child: Container(
                          decoration: BoxDecoration(
                            color: sketch.backgroundColor,
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CustomPaint(
                              painter: SketchPainter(strokes: sketch.strokes),
                              size: Size.infinite,
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
      final wasAdded =
          widget.note.attachments.length > _cachedAttachments.length;
      _cachedAttachments = List.from(widget.note.attachments);
      setState(() {});
      // Scroll to end if a new attachment was added
      if (wasAdded) {
        _scrollToEnd();
      }
    }
  }

  void _scrollToEnd() {
    if (widget.scrollController == null) return;
    // Wait for the frame to be rendered, then scroll
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.scrollController!.hasClients) {
        widget.scrollController!.animateTo(
          widget.scrollController!.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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
          if (a.image?.src != b.image?.src) return true;
        case AttachmentType.sketch:
          if (a.sketch?.previewImage != b.sketch?.previewImage ||
              a.sketch?.backgroundImage != b.sketch?.backgroundImage ||
              a.sketch?.blurredThumbnail != b.sketch?.blurredThumbnail) {
            return true;
          }
        case AttachmentType.audio:
          if (a.recording?.src != b.recording?.src) return true;
      }
    }
    return false;
  }
}
