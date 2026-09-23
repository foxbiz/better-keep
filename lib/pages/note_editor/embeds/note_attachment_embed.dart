import 'dart:async';
import 'dart:math' as math;

import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/pages/note_editor/embeds/note_embed_editing.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:uuid/uuid.dart';

const noteAttachmentEmbedType = 'note-attachment';

Map<String, dynamic> attachmentReference(NoteAttachment attachment) {
  attachment.id ??= const Uuid().v4();
  return {
    'id': const Uuid().v4(),
    'src': 'attachment://${attachment.id}',
    'placement': 'block',
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
    this.inlineWidth = 640,
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
    return _AttachmentFrame(
      key: ValueKey('${data['id']}:$offset'),
      data: data,
      ratio: ratio > 0 && ratio.isFinite ? ratio : 1,
      inlineWidth: inlineWidth,
      maxHeight: mediaMaxHeight ?? 400,
      controller: embedContext.controller,
      readOnly: embedContext.readOnly,
      editing: editing,
      offset: offset,
      child: content,
    );
  }
}

class _AttachmentFrame extends StatefulWidget {
  const _AttachmentFrame({
    super.key,
    required this.data,
    required this.ratio,
    required this.inlineWidth,
    required this.maxHeight,
    required this.controller,
    required this.readOnly,
    required this.editing,
    required this.offset,
    required this.child,
  });
  final Map<String, dynamic> data;
  final double ratio;
  final double inlineWidth;
  final double maxHeight;
  final QuillController controller;
  final bool readOnly;
  final NoteEmbedEditing? editing;
  final int offset;
  final Widget child;

  @override
  State<_AttachmentFrame> createState() => _AttachmentFrameState();
}

class _AttachmentFrameState extends State<_AttachmentFrame> {
  // Quill skips rebuilding embeds while focus-preserving changes are applied.
  // Keep the committed reference visible until its next document snapshot.
  late Map<String, dynamic> _data = widget.data;
  double? _resizingWidth;
  final _focus = FocusNode();
  Timer? _hideTimer;
  bool _controlsVisible = false;
  bool _resizing = false;
  bool _menuOpen = false;

  void _showControls() {
    if (widget.readOnly) return;
    setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_resizing && !_menuOpen) {
      _hideTimer = Timer(const Duration(seconds: 4), _hideControls);
    }
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (mounted && !_resizing && !_menuOpen) {
      setState(() => _controlsVisible = false);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_AttachmentFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    _data = widget.data;
    if (widget.readOnly) {
      _hideTimer?.cancel();
      _controlsVisible = false;
    }
  }

  double _startWidth = 0;
  Offset _drag = Offset.zero;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : widget.inlineWidth;
      final maximum = math.max(
        1.0,
        math.min(available, widget.maxHeight * widget.ratio),
      );
      final stored = _data['width'];
      final requested =
          _resizingWidth ??
          (stored is num && stored.isFinite && stored > 0
              ? stored.toDouble()
              : 640.0);
      final width = requested
          .clamp(math.min(40.0, maximum), maximum)
          .toDouble();
      final compactControls = width / widget.ratio < 76;
      final image = SizedBox(
        key: ValueKey('attachment_image_${_data['id']}'),
        width: width,
        height: width / widget.ratio,
        child: widget.child,
      );
      if (widget.readOnly || widget.editing == null) {
        return Align(
          alignment: Alignment.center,
          heightFactor: 1,
          child: image,
        );
      }
      return Align(
        alignment: Alignment.center,
        heightFactor: 1,
        child: NoteEmbedGestureRegion(
          editing: widget.editing!,
          owner: widget.controller,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Focus(
              focusNode: _focus,
              onKeyEvent: (_, event) {
                if (_focus.hasPrimaryFocus &&
                    event is KeyDownEvent &&
                    (event.logicalKey == LogicalKeyboardKey.enter ||
                        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                        event.logicalKey == LogicalKeyboardKey.space)) {
                  _showControls();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              onFocusChange: (focused) =>
                  focused ? _showControls() : _hideControls(),
              child: Stack(
                children: [
                  Semantics(
                    label: context.l10n.inNoteImage,
                    button: true,
                    child: GestureDetector(
                      onTap: _showControls,
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        // Keep the menu and grip tappable even on small images.
                        width: math.min(available, math.max(width, 76)),
                        height: math.max(width / widget.ratio, 48),
                        child: Center(child: image),
                      ),
                    ),
                  ),
                  if (_controlsVisible)
                    PositionedDirectional(
                      start: compactControls ? 0 : null,
                      end: compactControls ? null : 0,
                      top: 0,
                      child: PopupMenuButton<String>(
                        key: ValueKey('attachment_options_${_data['id']}'),
                        tooltip: context.l10n.inNoteImage,
                        icon: const Icon(Icons.more_horiz),
                        style: IconButton.styleFrom(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surface.withValues(alpha: 0.95),
                        ),
                        onOpened: () {
                          _menuOpen = true;
                          _hideTimer?.cancel();
                        },
                        onCanceled: () {
                          _menuOpen = false;
                          _scheduleHide();
                        },
                        onSelected: (action) {
                          _menuOpen = false;
                          _scheduleHide();
                          if (action == 'remove') {
                            replaceNoteEmbed(
                              widget.controller,
                              noteAttachmentEmbedType,
                              _data['id'] as String,
                              null,
                              offsetHint: widget.offset,
                            );
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'remove',
                            child: Text(context.l10n.removeImageReference),
                          ),
                        ],
                      ),
                    ),
                  if (_controlsVisible)
                    PositionedDirectional(
                      end: 0,
                      bottom: 0,
                      child: Semantics(
                        label: context.l10n.resizeImage,
                        child: Tooltip(
                          message: context.l10n.resizeImage,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.resizeUpLeftDownRight,
                            child: RawGestureDetector(
                              key: ValueKey('attachment_resize_${_data['id']}'),
                              behavior: HitTestBehavior.opaque,
                              gestures: {
                                _ImageResizeGestureRecognizer:
                                    GestureRecognizerFactoryWithHandlers<
                                      _ImageResizeGestureRecognizer
                                    >(
                                      _ImageResizeGestureRecognizer.new,
                                      (recognizer) => recognizer
                                        ..onStart = (_) {
                                          _resizing = true;
                                          _hideTimer?.cancel();
                                          _startWidth = width;
                                          _drag = Offset.zero;
                                        }
                                        ..onUpdate = (details) {
                                          _drag += details.delta;
                                          final dx =
                                              Directionality.of(context) ==
                                                  TextDirection.rtl
                                              ? -_drag.dx * 2
                                              : _drag.dx * 2;
                                          final delta =
                                              dx.abs() >=
                                                  (_drag.dy * widget.ratio)
                                                      .abs()
                                              ? dx
                                              : _drag.dy * widget.ratio;
                                          setState(
                                            () => _resizingWidth =
                                                (_startWidth + delta).clamp(
                                                  math.min(40.0, maximum),
                                                  maximum,
                                                ),
                                          );
                                        }
                                        ..onEnd = (_) {
                                          _finishResize();
                                        }
                                        ..onCancel = () {
                                          _resizing = false;
                                          setState(() => _resizingWidth = null);
                                          _scheduleHide();
                                        },
                                    ),
                              },
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surface.withValues(alpha: 0.95),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Icon(
                                  Icons.open_in_full,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  void _finishResize() {
    _resizing = false;
    _scheduleHide();
    final width = _resizingWidth;
    if (width == null) return;
    _data = {..._data, 'width': width};
    replaceNoteEmbed(
      widget.controller,
      noteAttachmentEmbedType,
      _data['id'] as String,
      _data,
      offsetHint: widget.offset,
    );
    if (mounted) setState(() => _resizingWidth = null);
  }
}

class _ImageResizeGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
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
