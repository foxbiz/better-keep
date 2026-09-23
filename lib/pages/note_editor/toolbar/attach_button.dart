import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:path/path.dart' as path;
import 'package:better_keep/config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/pages/note_editor/embeds/note_attachment_embed.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:image_picker/image_picker.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/components/adaptive_popup_menu.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/dialogs/audio_recorder_dialog.dart';
import 'package:better_keep/dialogs/attachment_commit_dialog.dart';
import 'package:better_keep/services/image_attachment_preparation_service.dart';
import 'package:better_keep/services/camera_detection.dart';
import 'package:better_keep/services/camera_capture.dart';

class AttachButton extends StatefulWidget {
  final Note note;
  final bool readOnly;
  final Color? parentColor;
  final void Function(String text, NoteRecording recording)? onAppendTranscript;
  final VoidCallback? onAttachmentAdded;
  final ImageAttachmentPreparationService? imageAttachmentPreparationService;
  final ValueChanged<NoteAttachment>? onInsertReference;

  const AttachButton({
    super.key,
    this.parentColor,
    required this.note,
    this.readOnly = false,
    this.onAppendTranscript,
    this.onAttachmentAdded,
    this.imageAttachmentPreparationService,
    this.onInsertReference,
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
  void didUpdateWidget(AttachButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.isDisabled = widget.readOnly;
  }

  @override
  Widget build(BuildContext context) {
    return AdaptivePopupMenu(
      controller: _controller,
      parentColor: widget.parentColor,
      showLabels: true,
      fitContent: true,
      items: (context) => [
        if (widget.onInsertReference != null)
          AdaptiveMenuItem(
            icon: Icons.collections_outlined,
            label: context.l10n.chooseAttachment,
            onTap: () async {
              _controller.close();
              final attachment = await showNoteAttachmentPicker(
                context,
                widget.note,
              );
              if (attachment != null && mounted && !widget.readOnly) {
                widget.onInsertReference?.call(attachment);
              }
            },
          ),
        AdaptiveMenuItem(
          icon: Icons.image,
          label: context.l10n.image,
          onTap: _showImageSourceDialog,
        ),
        if (widget.onInsertReference == null)
          AdaptiveMenuItem(
            icon: Icons.mic,
            label: context.l10n.audio,
            onTap: _handleAudio,
          ),
        AdaptiveMenuItem(
          icon: Icons.draw,
          label: context.l10n.sketch,
          onTap: _handleSketch,
        ),
      ],
      child: IconButton(
        padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 2, 8),
        onPressed: _controller.isDisabled ? null : _controller.toggle,
        icon: _buildIconWithIndicator(
          Icon(
            widget.onInsertReference == null
                ? Icons.attach_file
                : Icons.add_photo_alternate_outlined,
          ),
        ),
        tooltip: widget.onInsertReference == null
            ? context.l10n.attach
            : context.l10n.inNoteImage,
      ),
    );
  }

  Widget _buildIconWithIndicator(Widget icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [icon, const Icon(Icons.arrow_drop_down, size: 16)],
    );
  }

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

    var processingVisible = false;
    void showProcessing() {
      if (!mounted || processingVisible) return;
      processingVisible = true;
      showAttachmentProcessingDialog(context, context.l10n.processingImage);
    }

    void dismissProcessing() {
      if (!mounted || !processingVisible) return;
      dismissAttachmentProcessingDialog(context);
      processingVisible = false;
    }

    showProcessing();

    PreparedImageAttachment? preparedImage;
    try {
      preparedImage =
          await (widget.imageAttachmentPreparationService ??
                  ImageAttachmentPreparationService.platform())
              .prepare(
                sourceBytes: imageBytes,
                extension: ext,
                generateBlurredThumbnail: true,
              );

      final noteImage = NoteImage(
        src: preparedImage.path,
        aspectRatio:
            '${preparedImage.dimensions.width}:${preparedImage.dimensions.height}',
        size: preparedImage.byteLength,
        lastModified: DateTime.now().toIso8601String(),
        index: widget.note.images.length,
        blurredThumbnail: preparedImage.blurredThumbnail,
      );

      if (!mounted) return;
      final added = await commitAttachmentWithRetry(
        context: context,
        sourcePath: preparedImage.path,
        commit: () => widget.note.addImage(noteImage),
        beforeFailurePrompt: () async => dismissProcessing(),
        beforeRetry: () async => showProcessing(),
        sourceLease: preparedImage.sourceLease,
      );
      if (added && mounted) {
        widget.onAttachmentAdded?.call();
        final attachment = widget.note.attachments
            .where((a) => identical(a.image, noteImage))
            .firstOrNull;
        if (attachment != null && !widget.readOnly) {
          widget.onInsertReference?.call(attachment);
        }
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to prepare an image attachment',
        error,
        stackTrace,
      );
      if (mounted) {
        snackbar(context.l10n.attachmentCommitFailedTitle, Colors.red);
      }
    } finally {
      await preparedImage?.release();
      dismissProcessing();
    }
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
                title: Text(context.l10n.camera),
                onTap: () {
                  Navigator.pop(context);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.image),
                title: Text(context.l10n.gallery),
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
      final recording = NoteRecording(
        src: result.path,
        title: result.title,
        length: result.length,
        transcript: result.transcription,
      );
      final added = await commitAttachmentWithRetry(
        context: context,
        sourcePath: result.path,
        commit: () => widget.note.addRecording(recording),
      );
      if (!added || !mounted) return;
      widget.onAttachmentAdded?.call();
      // Append transcription to note if provided
      if (result.transcription != null &&
          result.transcription!.isNotEmpty &&
          widget.onAppendTranscript != null) {
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

    final previous = widget.note.attachments.toSet();

    await showPage(
      context,
      SketchPage(
        note: widget.note,
        sketch: SketchData(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
      allowFullScreen: true,
    );
    // Scroll to attachment after returning from sketch page if sketch was added
    widget.onAttachmentAdded?.call();
    if (mounted && !widget.readOnly && widget.onInsertReference != null) {
      final attachment = widget.note.attachments
          .where(
            (a) => !previous.contains(a) && a.type == AttachmentType.sketch,
          )
          .firstOrNull;
      if (attachment != null) widget.onInsertReference!(attachment);
    }
  }
}
