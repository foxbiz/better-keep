import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/dialogs/delete_dialog.dart';
import 'package:better_keep/ui/show_page.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/attachments/attachment.dart';
import 'package:better_keep/models/attachments/image_attachment.dart';
import 'package:better_keep/models/attachments/sketch_attachment.dart';
import 'package:better_keep/pages/sketch_page.dart';

class ImageViewer extends StatefulWidget {
  final Note note;
  final ImageAttachment image;
  final Attachment? attachment;
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
  late ImageAttachment _currentImage;

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
            tooltip: 'Scribble',
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _onDelete,
            tooltip: 'Delete',
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          child: Hero(
            tag: _currentImage.path,
            child: UniversalImage(
              path: _currentImage.path,
              errorBuilder: (context, error, stackTrace) {
                return const Center(
                  child: Icon(Icons.error, color: Colors.red),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _onDelete() async {
    final confirm = await showDeleteDialog(
      context,
      title: 'Delete Image',
      message: 'Are you sure you want to delete this image?',
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
        sketch: SketchAttachment(backgroundImage: _currentImage.path),
        sourceAttachment: widget.attachment,
      ),
    );
  }
}
