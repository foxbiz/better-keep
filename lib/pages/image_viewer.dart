import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/dialogs/delete_dialog.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/sketch_page.dart';

@visibleForTesting
const Key imageViewerHeroFrameKey = Key('image-viewer-hero-frame');

double _finitePositiveDimension(double value, [double fallback = 1.0]) {
  if (value.isFinite && value > 0) return value;
  if (fallback.isFinite && fallback > 0) return fallback;
  return 1.0;
}

/// Returns the largest finite image frame that fits inside [viewport] while
/// preserving [aspectRatio]. Invalid geometry falls back to a square.
@visibleForTesting
Size calculateImageViewerFrameSize(Size viewport, double aspectRatio) {
  final viewportWidth = _finitePositiveDimension(viewport.width);
  final viewportHeight = _finitePositiveDimension(viewport.height);
  final safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0
      ? aspectRatio
      : 1.0;
  final viewportRatio = viewportWidth / viewportHeight;

  final size = safeAspectRatio >= viewportRatio
      ? Size(viewportWidth, viewportWidth / safeAspectRatio)
      : Size(viewportHeight * safeAspectRatio, viewportHeight);
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0) {
    final side = viewportWidth < viewportHeight
        ? viewportWidth
        : viewportHeight;
    return Size.square(side);
  }
  return size;
}

class ImageViewer extends StatefulWidget {
  final Note note;
  final NoteImage image;
  final NoteAttachment? attachment;
  final String? heroTag;

  const ImageViewer({
    super.key,
    required this.note,
    required this.image,
    this.attachment,
    this.heroTag,
  });

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  late NoteImage _currentImage;

  @override
  void initState() {
    super.initState();
    _currentImage = widget.image;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: BackButton(onPressed: () => Navigator.pop(context)),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _onScribble,
            tooltip: context.l10n.scribble,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _onDelete,
            tooltip: context.l10n.delete,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final mediaSize = MediaQuery.sizeOf(context);
          final viewport = Size(
            _finitePositiveDimension(constraints.maxWidth, mediaSize.width),
            _finitePositiveDimension(constraints.maxHeight, mediaSize.height),
          );
          final imageFrame = calculateImageViewerFrameSize(
            viewport,
            _currentImage.ratio,
          );

          return InteractiveViewer(
            child: SizedBox(
              width: viewport.width,
              height: viewport.height,
              child: Center(
                child: Hero(
                  tag:
                      widget.heroTag ??
                      "image_${widget.note.id}_${_currentImage.src}",
                  child: SizedBox(
                    key: imageViewerHeroFrameKey,
                    width: imageFrame.width,
                    height: imageFrame.height,
                    child: ColoredBox(
                      color: Colors.black,
                      child: UniversalImage(
                        path: _currentImage.src,
                        fit: BoxFit.contain,
                        passwordProtectedDecoder:
                            widget.note.locked && widget.note.unlocked
                            ? widget.note.decryptAttachmentForSession
                            : null,
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(
                            child: Icon(Icons.error, color: Colors.red),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _onDelete() async {
    final confirm = await showDeleteDialog(
      context,
      title: context.l10n.deleteImage,
      message: context.l10n.deleteImageConfirmation,
    );

    if (confirm == true && mounted) {
      widget.note.removeImage(widget.image);
      Navigator.pop(context); // Close viewer
    }
  }

  void _onScribble() {
    showPage(
      context,
      SketchPage(
        note: widget.note,
        sketch: SketchData(
          backgroundImage: _currentImage.src,
          aspectRatio: _currentImage.ratio,
        ),
        sourceAttachment: widget.attachment,
      ),
    );
  }
}
