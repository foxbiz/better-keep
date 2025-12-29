import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
import 'package:path/path.dart' as path;
import 'package:better_keep/config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:image_picker/image_picker.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/components/adaptive_popup_menu.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:better_keep/dialogs/audio_recorder_dialog.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/camera_detection.dart';
import 'package:better_keep/services/camera_capture.dart';

class AttachButton extends StatefulWidget {
  final Note note;
  final bool readOnly;
  final Color? parentColor;
  final void Function(String text, NoteRecording recording)? onAppendTranscript;

  const AttachButton({
    super.key,
    this.parentColor,
    required this.note,
    this.readOnly = false,
    this.onAppendTranscript,
  });

  @override
  State<AttachButton> createState() => _AttachButtonState();
}

class _AttachButtonState extends State<AttachButton> {
  final AdaptivePopupController _controller = AdaptivePopupController();

  @override
  void initState() {
    _controller.isDisabled = widget.readOnly;
    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AdaptivePopupMenu(
      controller: _controller,
      parentColor: widget.parentColor,
      showLabels: true,
      items: (context) => [
        AdaptiveMenuItem(
          icon: Icons.image,
          label: 'Image',
          onTap: _showImageSourceDialog,
        ),
        AdaptiveMenuItem(icon: Icons.mic, label: 'Audio', onTap: _handleAudio),
        AdaptiveMenuItem(
          icon: Icons.draw,
          label: 'Sketch',
          onTap: _handleSketch,
        ),
      ],
      child: IconButton(
        onPressed: _controller.isDisabled ? null : _controller.toggle,
        icon: const Icon(Icons.attach_file),
        tooltip: 'Attach',
      ),
    );
  }

  /// Maximum image size in bytes (500KB)
  static const int _maxImageSize = 500 * 1024;

  /// Check if attachment limit is reached and show snackbar if so.
  bool _checkAttachmentLimit() {
    if (widget.note.attachments.length >= maxAttachmentsPerNote) {
      snackbar(
        'Maximum $maxAttachmentsPerNote attachments per note reached',
        Colors.orange,
      );
      return true;
    }
    return false;
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_checkAttachmentLimit()) return;

    Uint8List? imageBytes;
    String ext = '.jpg';

    // On web with camera source, use the web camera capture
    if (kIsWeb && source == ImageSource.camera) {
      imageBytes = await captureImageFromWebCamera();
      if (imageBytes == null) return;
    } else {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: source);
      if (image == null) return;
      imageBytes = await image.readAsBytes();
      ext = path.extension(image.path);
      if (ext.isEmpty) ext = '.jpg';
    }

    // Show loading dialog while processing
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const PopScope(
          canPop: false,
          child: Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Processing image...'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    try {
      final fs = await fileSystem();
      final documentDir = await fs.documentDir;
      final imagePath = path.join(
        documentDir,
        'images',
        '${DateTime.now().millisecondsSinceEpoch}$ext',
      );

      // Compress the image to be under 500KB
      Uint8List bytes = await _compressImageToTargetSize(imageBytes);

      await writeEncryptedBytes(imagePath, bytes);

      final decodedImage = await decodeImageFromList(bytes);

      // Generate tiny thumbnail for locked note preview (under 1KB)
      final thumbnail = await ThumbnailGenerator.generateFromBytes(bytes);

      final noteImage = NoteImage(
        src: imagePath,
        aspectRatio: "${decodedImage.width}:${decodedImage.height}",
        size: bytes.length,
        lastModified: DateTime.now().toIso8601String(),
        index: widget.note.images.length,
        blurredThumbnail: thumbnail,
      );

      widget.note.addImage(noteImage);
    } finally {
      // Dismiss loading dialog
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    }
  }

  /// Compresses an image to be under [_maxImageSize] bytes.
  /// Progressively reduces quality and size until target is met.
  Future<Uint8List> _compressImageToTargetSize(Uint8List imageBytes) async {
    // If already under target, just do a light compression
    if (imageBytes.length <= _maxImageSize) {
      return await FlutterImageCompress.compressWithList(
        imageBytes,
        quality: 90,
      );
    }

    // Start with quality 85 and full size
    int quality = 85;
    int minWidth = 1920;
    int minHeight = 1920;
    Uint8List compressed = imageBytes;

    // Try progressively lower quality first
    while (quality >= 50) {
      compressed = await FlutterImageCompress.compressWithList(
        imageBytes,
        quality: quality,
        minWidth: minWidth,
        minHeight: minHeight,
      );

      if (compressed.length <= _maxImageSize) {
        return compressed;
      }

      quality -= 10;
    }

    // If still too large, reduce dimensions progressively
    quality = 70;
    while (minWidth >= 800) {
      compressed = await FlutterImageCompress.compressWithList(
        imageBytes,
        quality: quality,
        minWidth: minWidth,
        minHeight: minHeight,
      );

      if (compressed.length <= _maxImageSize) {
        return compressed;
      }

      minWidth = (minWidth * 0.75).toInt();
      minHeight = (minHeight * 0.75).toInt();
    }

    // Final attempt with minimum settings
    return await FlutterImageCompress.compressWithList(
      imageBytes,
      quality: 50,
      minWidth: 800,
      minHeight: 800,
    );
  }

  void _showImageSourceDialog() async {
    _controller.close();
    // On desktop, directly pick from gallery
    if (isDesktop) {
      _pickImage(ImageSource.gallery);
      return;
    }

    // On web, check if camera is available
    if (kIsWeb) {
      final hasCamera = await hasCameraAvailable();
      if (!hasCamera) {
        _pickImage(ImageSource.gallery);
        return;
      }
    }

    // Show bottom sheet with camera/gallery options
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Camera'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.image),
                title: const Text('Gallery'),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleAudio() async {
    if (_checkAttachmentLimit()) return;

    _controller.close();
    final result = await showDialog<AudioRecordingResult>(
      context: context,
      builder: (context) => const AudioRecorderDialog(),
    );

    if (result != null && mounted) {
      widget.note.addRecording(
        NoteRecording(
          src: result.path,
          title: result.title,
          length: result.length,
          transcript: result.transcription,
        ),
      );
      // Append transcription to note if provided
      if (result.transcription != null &&
          result.transcription!.isNotEmpty &&
          widget.onAppendTranscript != null) {
        final recording = NoteRecording(
          src: result.path,
          title: result.title,
          length: result.length,
          transcript: result.transcription,
        );
        widget.onAppendTranscript!(result.transcription!, recording);
      }
      // Set note title from first few words if note has no title
      if ((widget.note.title == null || widget.note.title!.isEmpty) &&
          result.transcription != null &&
          result.transcription!.isNotEmpty) {
        final words = result.transcription!
            .split(' ')
            .where((w) => w.isNotEmpty)
            .toList();
        if (words.isNotEmpty) {
          final titleWords = words.take(5).join(' ');
          widget.note.title = titleWords + (words.length > 5 ? '...' : '');
        }
      }
    }
  }

  void _handleSketch() async {
    if (_checkAttachmentLimit()) return;

    _controller.close();

    showPage(
      context,
      SketchPage(
        note: widget.note,
        sketch: SketchData(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
    );
  }
}
