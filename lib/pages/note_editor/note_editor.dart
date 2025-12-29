import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:better_keep/components/adaptive_toolbar.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/pages/note_editor/toolbar/align_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/attach_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/checklist_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/link_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/style_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/text_color_button.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/ui/paywall/paywall.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:better_keep/components/note_attachments_carousel.dart';
import 'package:better_keep/components/note_audio_player.dart';
import 'package:better_keep/dialogs/color_picker.dart';
import 'package:better_keep/dialogs/labels.dart';
import 'package:better_keep/dialogs/lock_note_dialog.dart';
import 'package:better_keep/dialogs/reminder.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class NoteEditor extends StatefulWidget {
  final Note? note;
  final bool autoFocus;
  final bool deleteIfUnchanged;
  const NoteEditor({
    super.key,
    this.note,
    this.autoFocus = false,
    this.deleteIfUnchanged = false,
  });

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> with WidgetsBindingObserver {
  static final Map<String, Metadata> _metadataCache = {};
  static final Map<String, MemoryImage> _base64ImageCache = {};
  static const int _maxCacheSize = 10;
  static const int _maxImageCacheSize = 50;

  StreamSubscription? _changesSubscription;
  String? _title;
  String? _linkUrl;
  Timer? _changeTimer;
  Metadata? _linkMetadata;
  bool _isLoadingMetadata = false;

  final ScrollController _quillScrollController = ScrollController();
  final Map<String, GlobalKey> _audioPlayerKeys = {};
  late final Note _note;
  late FocusNode _focusNode;
  late QuillController _controller;
  late Color _backgroundColor;
  bool _isKeyboardVisible = false;
  String? _initialPlainText;

  bool get _isEditingTitle {
    final selection = _controller.selection;
    final start = selection.start;
    final firstLine = _controller.document.toPlainText().split('\n').first;
    final offset = firstLine.length;
    return start <= offset;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.note == null) {
      _note = Note(content: '');
    } else {
      _note = widget.note!;
    }

    _focusNode = FocusNode(canRequestFocus: true);
    _backgroundColor = _note.color;

    Document document = _note.content != ''
        ? Document.fromJson(json.decode(_note.content as String))
        : Document();

    _controller = QuillController(
      readOnly: _note.readOnly || _note.trashed,
      document: document,
      selection: TextSelection.collapsed(offset: document.length - 1),
    );

    // Store initial plain text for deleteIfUnchanged check
    if (widget.deleteIfUnchanged) {
      _initialPlainText = _controller.document.toPlainText().trim();
    }

    _controller.addListener(_didChangeSelection);
    _changesSubscription = _controller.changes.listen(
      _controllerChangesListener,
    );

    // Subscribe to note changes for audio recordings
    _note.sub("changed", _onNoteChanged);
  }

  void _onNoteChanged(dynamic _) {
    if (mounted) {
      setState(() {});
    }
  }

  void _appendTranscriptToNote(String text, NoteRecording recording) {
    if (text.isEmpty) return;

    final document = _controller.document;
    final length = document.length;

    // Get the title length (first line) to preserve its formatting
    final plainText = document.toPlainText();
    final firstLineEnd = plainText.indexOf('\n');
    final titleLength = firstLineEnd > 0 ? firstLineEnd : 0;

    // Find the index of this recording in attachments
    final recordingIndex = _note.recordings.indexWhere(
      (r) => r.src == recording.src,
    );

    // Create audio tag text with # prefix
    final audioTitle = recording.title ?? 'Audio Recording';
    final audioTag = '#$audioTitle';

    // Insert: newline + audio tag + newline + transcript text
    // Both tag and transcript will be inside the blockquote
    final insertText = '\n$audioTag\n$text';
    document.insert(length - 1, insertText);

    // Calculate positions for formatting
    final audioTagStart = length + 1; // After the two newlines
    final audioTagLength = audioTag.length;
    final transcriptStart =
        audioTagStart + audioTagLength + 1; // After audio tag and newline
    final transcriptLength = text.length;

    // Format audio tag as a link with audio://index scheme
    // Using index makes it easy to recreate on synced devices
    _controller.formatText(
      audioTagStart,
      audioTagLength,
      LinkAttribute('audio://$recordingIndex'),
    );

    // Make audio tag bold
    _controller.formatText(audioTagStart, audioTagLength, Attribute.bold);

    // Apply blockquote to both audio tag and transcript text
    _controller.formatText(audioTagStart, audioTagLength, Attribute.blockQuote);
    _controller.formatText(
      transcriptStart,
      transcriptLength,
      Attribute.blockQuote,
    );

    // Re-apply h1 to the title line to ensure it's preserved
    if (titleLength > 0) {
      _controller.formatText(0, titleLength, Attribute.h1);
    }

    // Move cursor to the end
    _controller.updateSelection(
      TextSelection.collapsed(offset: length - 1 + insertText.length),
      ChangeSource.local,
    );
  }

  /// Custom link action picker that disables long-press menu for audio:// links
  Future<LinkMenuAction> _audioLinkActionPicker(
    BuildContext context,
    String link,
    Node node,
  ) async {
    // For audio links, don't show any menu - just return none
    if (link.startsWith('audio://')) {
      return LinkMenuAction.none;
    }
    // For other links, use default behavior
    return defaultLinkActionPickerDelegate(context, link, node);
  }

  /// Remove audio link tags from document when a recording is deleted
  void _removeAudioTagsForIndex(int index) {
    final document = _controller.document;
    final delta = document.toDelta();

    // Find and remove links with audio://index format
    final targetLink = 'audio://$index';
    int offset = 0;

    for (final op in delta.toList()) {
      if (op.isInsert) {
        final data = op.data;
        if (data is String) {
          final attributes = op.attributes;
          if (attributes != null && attributes['link'] == targetLink) {
            // Remove the link attribute from this text
            _controller.formatText(
              offset,
              data.length,
              LinkAttribute(null), // Remove link
            );
          }
          offset += data.length;
        } else {
          offset += 1; // Embed
        }
      }
    }

    // Also update any links with higher indices (shift down by 1)
    _updateAudioLinkIndices(index);
  }

  /// Update audio link indices after a recording is removed
  void _updateAudioLinkIndices(int removedIndex) {
    final document = _controller.document;
    final delta = document.toDelta();

    int offset = 0;

    for (final op in delta.toList()) {
      if (op.isInsert) {
        final data = op.data;
        if (data is String) {
          final attributes = op.attributes;
          if (attributes != null) {
            final link = attributes['link'] as String?;
            if (link != null && link.startsWith('audio://')) {
              final indexStr = link.substring(8); // Remove 'audio://'
              final linkIndex = int.tryParse(indexStr);
              if (linkIndex != null && linkIndex > removedIndex) {
                // Update to new index (shifted down by 1)
                final newLink = 'audio://${linkIndex - 1}';
                _controller.formatText(
                  offset,
                  data.length,
                  LinkAttribute(newLink),
                );
              }
            }
          }
          offset += data.length;
        } else {
          offset += 1; // Embed
        }
      }
    }
  }

  /// Get recording by audio link index
  NoteRecording? _getRecordingByIndex(int index) {
    final recordings = _note.recordings;
    if (index >= 0 && index < recordings.length) {
      return recordings[index];
    }
    return null;
  }

  void _scrollToAndPlayAudio(String audioSrc) {
    final key = _audioPlayerKeys[audioSrc];
    if (key?.currentContext != null) {
      // Scroll to the audio player
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      ).then((_) {
        // Start playing after scroll completes
        final state = key.currentState;
        if (state is NoteAudioPlayerState) {
          state.play();
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changeTimer?.cancel();
    _changesSubscription?.cancel();
    _saveNote();
    _controller.removeListener(_didChangeSelection);
    _controller.dispose();
    _note.unsub("changed", _onNoteChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _changeTimer?.cancel();
      _saveNote();
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Check keyboard visibility based on view insets
    final bottomInset = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .first
        .viewInsets
        .bottom;
    final keyboardVisible = bottomInset > 0;
    if (_isKeyboardVisible != keyboardVisible) {
      setState(() {
        _isKeyboardVisible = keyboardVisible;
      });
    }
  }

  Widget? _buildAppBarTitle(Color foregroundColor) {
    final hasCheckboxes = _note.hasCheckboxes;

    if (!hasCheckboxes) return null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final children = <Widget>[];

        // Add checkbox progress
        if (hasCheckboxes) {
          final checkboxCount = _note.checkboxCount;
          final progress = _note.checkboxProgress;
          final isComplete = progress == 1.0;

          children.add(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isComplete ? Icons.check_circle : Icons.checklist,
                  size: 18,
                  color: isComplete
                      ? Colors.green
                      : foregroundColor.withAlpha(180),
                ),
                SizedBox(width: 4),
                Text(
                  '${checkboxCount.checked}/${checkboxCount.total}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: isComplete ? Colors.green : foregroundColor,
                  ),
                ),
              ],
            ),
          );
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final defaultStyles = DefaultStyles();

    Color backgroundColor = _backgroundColor == Colors.transparent
        ? Theme.of(context).colorScheme.surface
        : _backgroundColor;

    late Color foregroundColor;
    late Color placeholderColor;

    if (isDark(backgroundColor)) {
      foregroundColor = Colors.white;
      placeholderColor = Colors.white30;
    } else {
      foregroundColor = Colors.black;
      placeholderColor = Colors.black38;
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        _changeTimer?.cancel();
        _saveNote();
        if (didPop) return;
        Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          iconTheme: IconThemeData(color: foregroundColor),
          actionsIconTheme: IconThemeData(color: foregroundColor),
          leading: BackButton(color: foregroundColor),
          title: _buildAppBarTitle(foregroundColor),
          centerTitle: true,
          actions: _note.trashed
              ? [
                  IconButton(
                    color: foregroundColor,
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      await _note.restoreFromTrash();
                      if (mounted) {
                        navigator.pop();
                      }
                    },
                    icon: Icon(Icons.restore_from_trash),
                    tooltip: 'Restore',
                  ),
                ]
              : [
                  _toolNoteColor(_note.color, foregroundColor),
                  IconButton(
                    color: foregroundColor,
                    onPressed: () async {
                      final res = await reminder(context);
                      if (res != null) {
                        await _note.setReminder(res);
                        setState(() {});
                      }
                    },
                    icon: Icon(
                      _note.hasReminder
                          ? (_note.completed
                                ? Icons.notifications_off
                                : (_note.hasReminderExpired
                                      ? Icons.notification_important
                                      : Icons.notifications_active))
                          : Icons.notifications_none,
                    ),
                    tooltip: 'Reminder',
                  ),
                  IconButton(
                    color: foregroundColor,
                    onPressed: () {
                      _note.pinned = !_note.pinned;
                      _note.save();
                      setState(() {});
                    },
                    icon: Icon(
                      _note.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                    ),
                  ),
                  PopupMenuButton(itemBuilder: _buildPopupMenu),
                ],
        ),
        backgroundColor: backgroundColor,
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                controller: _quillScrollController,
                child: Column(
                  children: [
                    NoteAttachmentsCarousel(
                      note: _note,
                      onPop: () => setState(() {}),
                    ),
                    Theme(
                      data: Theme.of(context).copyWith(
                        checkboxTheme: CheckboxThemeData(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          side: BorderSide(width: 2, color: foregroundColor),
                          splashRadius: 24,
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                        ),
                      ),
                      child: DefaultTextStyle(
                        style: TextStyle(color: foregroundColor),
                        child: QuillEditor.basic(
                          scrollController: _quillScrollController,
                          focusNode: _focusNode,
                          controller: _controller,
                          config: QuillEditorConfig(
                            checkBoxReadOnly: _note.trashed,
                            scrollable: false,
                            padding: EdgeInsets.only(
                              bottom: 32,
                              left: 16,
                              right: 16,
                            ),
                            readOnlyMouseCursor: SystemMouseCursors.alias,
                            showCursor: !_note.readOnly && !_note.trashed,
                            enableInteractiveSelection: true,
                            enableSelectionToolbar: true,
                            placeholder: 'Start typing your note...',
                            customStyles: DefaultStyles(
                              // Default text color based on note background
                              color: foregroundColor,
                              paragraph: DefaultTextBlockStyle(
                                TextStyle(fontSize: 16, color: foregroundColor),
                                HorizontalSpacing.zero,
                                VerticalSpacing.zero,
                                VerticalSpacing.zero,
                                null,
                              ),
                              h1: DefaultTextBlockStyle(
                                (defaultStyles.h1?.style ??
                                        TextStyle(fontSize: 28))
                                    .copyWith(color: foregroundColor),
                                defaultStyles.h1?.horizontalSpacing ??
                                    HorizontalSpacing.zero,
                                VerticalSpacing(0, 10),
                                defaultStyles.h1?.lineSpacing ??
                                    VerticalSpacing.zero,
                                defaultStyles.h1?.decoration,
                              ),
                              h2: DefaultTextBlockStyle(
                                (defaultStyles.h2?.style ??
                                        TextStyle(fontSize: 24))
                                    .copyWith(color: foregroundColor),
                                defaultStyles.h2?.horizontalSpacing ??
                                    HorizontalSpacing.zero,
                                defaultStyles.h2?.verticalSpacing ??
                                    VerticalSpacing.zero,
                                defaultStyles.h2?.lineSpacing ??
                                    VerticalSpacing.zero,
                                defaultStyles.h2?.decoration,
                              ),
                              h3: DefaultTextBlockStyle(
                                (defaultStyles.h3?.style ??
                                        TextStyle(fontSize: 20))
                                    .copyWith(color: foregroundColor),
                                defaultStyles.h3?.horizontalSpacing ??
                                    HorizontalSpacing.zero,
                                defaultStyles.h3?.verticalSpacing ??
                                    VerticalSpacing.zero,
                                defaultStyles.h3?.lineSpacing ??
                                    VerticalSpacing.zero,
                                defaultStyles.h3?.decoration,
                              ),
                              placeHolder: DefaultTextBlockStyle(
                                TextStyle(
                                  fontSize: 16,
                                  color: placeholderColor,
                                ),
                                HorizontalSpacing.zero,
                                VerticalSpacing.zero,
                                VerticalSpacing.zero,
                                null,
                              ),
                              // Inline styles with proper foreground color
                              bold: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: foregroundColor,
                              ),
                              italic: TextStyle(
                                fontStyle: FontStyle.italic,
                                color: foregroundColor,
                              ),
                              underline: TextStyle(
                                decoration: TextDecoration.underline,
                                decorationColor: foregroundColor,
                                color: foregroundColor,
                              ),
                              strikeThrough: TextStyle(
                                decoration: TextDecoration.lineThrough,
                                decorationColor: foregroundColor,
                                color: foregroundColor,
                              ),
                              link: TextStyle(
                                color: isDark(backgroundColor)
                                    ? Colors.lightBlueAccent
                                    : Colors.blue,
                                decoration: TextDecoration.underline,
                              ),
                              code: DefaultTextBlockStyle(
                                TextStyle(
                                  fontSize: 14,
                                  color: foregroundColor,
                                  fontFamily: 'monospace',
                                ),
                                HorizontalSpacing.zero,
                                VerticalSpacing(4, 4),
                                VerticalSpacing.zero,
                                BoxDecoration(
                                  color: isDark(backgroundColor)
                                      ? Colors.white.withAlpha(20)
                                      : Colors.black.withAlpha(15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              inlineCode: InlineCodeStyle(
                                style: TextStyle(
                                  fontSize: 14,
                                  color: foregroundColor,
                                  fontFamily: 'monospace',
                                ),
                                backgroundColor: isDark(backgroundColor)
                                    ? Colors.white.withAlpha(20)
                                    : Colors.black.withAlpha(15),
                                radius: const Radius.circular(4),
                              ),
                            ),
                            embedBuilders: kIsWeb
                                ? FlutterQuillEmbeds.editorWebBuilders()
                                : FlutterQuillEmbeds.editorBuilders(
                                    imageEmbedConfig: QuillEditorImageEmbedConfig(
                                      imageProviderBuilder: (context, imageUrl) {
                                        if (imageUrl.startsWith('http://') ||
                                            imageUrl.startsWith('https://')) {
                                          return NetworkImage(imageUrl);
                                        } else if (imageUrl.startsWith(
                                          'data:image/',
                                        )) {
                                          // Check cache first
                                          if (_base64ImageCache.containsKey(
                                            imageUrl,
                                          )) {
                                            return _base64ImageCache[imageUrl];
                                          }
                                          // Handle base64 data URLs
                                          try {
                                            final regex = RegExp(
                                              r'^data:image/[^;]+;base64,(.+)$',
                                            );
                                            final match = regex.firstMatch(
                                              imageUrl,
                                            );
                                            if (match != null) {
                                              final base64Data = match.group(
                                                1,
                                              )!;
                                              final bytes = base64Decode(
                                                base64Data,
                                              );
                                              final image = MemoryImage(bytes);
                                              // Cache with size limit
                                              if (_base64ImageCache.length >=
                                                  _maxImageCacheSize) {
                                                _base64ImageCache.remove(
                                                  _base64ImageCache.keys.first,
                                                );
                                              }
                                              _base64ImageCache[imageUrl] =
                                                  image;
                                              return image;
                                            }
                                          } catch (e) {
                                            AppLogger.error(
                                              '[NoteEditor] Failed to decode data URL',
                                              e,
                                            );
                                          }
                                        }
                                        // Fallback: try as file path
                                        return null;
                                      },
                                      imageErrorWidgetBuilder:
                                          (context, error, stackTrace) {
                                            return Container(
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(
                                                color: Colors.grey.withAlpha(
                                                  50,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.broken_image_outlined,
                                                    size: 16,
                                                    color: Colors.grey,
                                                  ),
                                                  SizedBox(width: 4),
                                                  Text(
                                                    'Image failed to load',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                    ),
                                  ),
                            autoFocus:
                                widget.autoFocus ||
                                (!_note.readOnly && _note.content == ''),
                            customLinkPrefixes: const ['audio://'],
                            linkActionPickerDelegate: _audioLinkActionPicker,
                            onLaunchUrl: (url) {
                              // Don't launch URLs on tap - just show the preview
                              // The preview handles launching when clicked
                              return;
                            },
                          ),
                        ),
                      ),
                    ),
                    ..._note.recordings.asMap().entries.map((entry) {
                      final index = entry.key;
                      final recording = entry.value;
                      // Get or create a key for this audio player
                      _audioPlayerKeys[recording.src] ??= GlobalKey();
                      return NoteAudioPlayer(
                        key: _audioPlayerKeys[recording.src],
                        recording: recording,
                        onDelete: () async {
                          // Remove audio tag from document before deleting recording
                          _removeAudioTagsForIndex(index);
                          await _note.removeRecording(recording.src);
                          _audioPlayerKeys.remove(recording.src);
                          setState(() {});
                        },
                        onUpdate: (updatedRecording) async {
                          await _note.updateRecording(updatedRecording);
                          setState(() {});
                        },
                      );
                    }),
                  ],
                ),
              ),
            ),
            if (!_note.trashed && !_note.readOnly)
              _buildLinkPreview(backgroundColor, foregroundColor),
            ClipRect(
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                offset: (!_note.trashed && !_note.readOnly)
                    ? Offset.zero
                    : const Offset(0, 1),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  opacity: (!_note.trashed && !_note.readOnly) ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: _note.trashed || _note.readOnly,
                    child: RepaintBoundary(child: _buildToolbar()),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final noteColor = _note.color;
    Color textColor = isDark(noteColor) ? Colors.white : Colors.black;
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;

    final toolbarItems = <Widget>[
      QuillToolbarHistoryButton(controller: _controller, isUndo: true),
      QuillToolbarHistoryButton(controller: _controller, isUndo: false),
      AttachButton(
        readOnly: _note.readOnly,
        note: _note,
        onAppendTranscript: _appendTranscriptToNote,
      ),
      TextColorButton(
        color: textColor,
        focusNode: _focusNode,
        readOnly: _note.readOnly,
        controller: _controller,
        isEditingTitle: _isEditingTitle,
      ),
      CheckListButton(
        focusNode: _focusNode,
        controller: _controller,
        readOnly: _note.readOnly,
        isEditingTitle: _isEditingTitle,
      ),
      LinkButton(
        controller: _controller,
        readOnly: _note.readOnly,
        isEditingTitle: _isEditingTitle,
      ),
      _styleButton(Attribute.ul),
      _styleButton(Attribute.ol),
      _styleButton(Attribute.strikeThrough),
      _styleButton(Attribute.bold),
      _styleButton(Attribute.italic),
      _styleButton(Attribute.underline),
      AlignButton(
        focusNode: _focusNode,
        controller: _controller,
        readOnly: _note.readOnly,
        isEditingTitle: _isEditingTitle,
      ),
    ];

    return AdaptiveToolbar(
      parentColor: noteColor,
      child: CustomScrollView(
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        slivers: [
          // Keyboard dismiss button for iOS - first, only when keyboard visible
          if (isIOS)
            SliverToBoxAdapter(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: _isKeyboardVisible
                    ? IconButton(
                        icon: const Icon(Icons.keyboard_hide),
                        onPressed: () => _focusNode.unfocus(),
                        tooltip: 'Hide keyboard',
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ...toolbarItems.map((el) => SliverToBoxAdapter(child: el)),
        ],
      ),
    );
  }

  Widget _styleButton(Attribute attribute) {
    return StyleButton(
      attribute: attribute,
      controller: _controller,
      readOnly: _note.readOnly,
      isEditingTitle: _isEditingTitle,
    );
  }

  void _saveNote() async {
    // If deleteIfUnchanged is set and content hasn't meaningfully changed, delete instead of save
    if (widget.deleteIfUnchanged && _initialPlainText != null) {
      final currentPlainText = _controller.document.toPlainText().trim();
      if (currentPlainText == _initialPlainText) {
        try {
          await _note.delete();
        } catch (e) {
          AppLogger.error('Error deleting unchanged note', e);
        }
        return;
      }
    }

    if (_note.isEmpty) {
      try {
        await _note.delete();
      } catch (e) {
        AppLogger.error('Error saving note', e);
        snackbar("Error saving note", Colors.red);
      }
      return;
    }

    final oldContent = _note.content;
    final newContent = json.encode(_controller.document.toDelta().toJson());

    if (oldContent == newContent) {
      return;
    }

    try {
      final plainText = _controller.document.toPlainText().trim();
      await _note.setContent(newContent, plainText);
    } catch (e) {
      AppLogger.error('Error saving note', e);
      snackbar("Error saving note", Colors.red);
    }
  }

  Widget _toolNoteColor(Color noteColor, Color iconColor) {
    return IconButton(
      icon: Icon(Icons.color_lens),
      color: iconColor,
      onPressed: () async {
        _focusNode.unfocus();
        final color = await colorPicker(context, "Pick Note Color", noteColor);
        _focusNode.requestFocus();
        if (color == null) return;
        _note.color = color;
        _note.save();
        setState(() {
          _backgroundColor = color;
        });
      },
    );
  }

  Future<void> _fetchMetadata(String url) async {
    if (_linkMetadata?.url == url) return;

    // Check cache first
    if (_metadataCache.containsKey(url)) {
      if (mounted) {
        setState(() {
          _linkMetadata = _metadataCache[url];
          _isLoadingMetadata = false;
        });
      }
      return;
    }

    setState(() {
      _isLoadingMetadata = true;
      _linkMetadata = null;
    });

    try {
      final data = await MetadataFetch.extract(url);
      if (data != null) {
        // Update cache
        _metadataCache[url] = data;
        if (_metadataCache.length > _maxCacheSize) {
          _metadataCache.remove(_metadataCache.keys.first);
        }
      }

      if (mounted && _linkUrl == url) {
        setState(() {
          _linkMetadata = data;
          _isLoadingMetadata = false;
        });
      }
    } catch (e) {
      if (mounted && _linkUrl == url) {
        setState(() {
          _isLoadingMetadata = false;
        });
      }
    }
  }

  /// Finds a link at or near the given position, but not across whitespace
  /// Shows link preview if:
  /// - [cursor]{text with link} - cursor directly before link text
  /// - {text with link}[cursor] - cursor directly after link text
  /// Does NOT show if there's whitespace between cursor and link
  String? _findNearbyLink(int position) {
    final doc = _controller.document;
    final docLength = doc.length;
    final plainText = doc.toPlainText();

    // Check current position (cursor is before this character)
    // This handles: [cursor]{text with link}
    if (position >= 0 && position < docLength) {
      final styles = doc.collectStyle(position, 0);
      final link = styles.attributes[Attribute.link.key]?.value;
      if (link != null) return link;
    }

    // Check position before (cursor is after this character)
    // This handles: {text with link}[cursor]
    // But NOT: {text with link}<whitespace>[cursor]
    final posBefore = position - 1;
    if (posBefore >= 0 && posBefore < plainText.length) {
      // Check if the character before cursor is NOT whitespace
      final charBefore = plainText[posBefore];
      if (!_isWhitespace(charBefore)) {
        final styles = doc.collectStyle(posBefore, 0);
        final link = styles.attributes[Attribute.link.key]?.value;
        if (link != null) return link;
      }
    }

    return null;
  }

  bool _isWhitespace(String char) {
    return char == ' ' || char == '\n' || char == '\t' || char == '\r';
  }

  void _didChangeSelection() {
    final selection = _controller.selection;
    final position = selection.baseOffset;

    // First check exact position
    final styles = _controller.getSelectionStyle();
    String? link = styles.attributes[Attribute.link.key]?.value;

    // If no link at exact position, check nearby
    link ??= _findNearbyLink(position);

    if (link != _linkUrl) {
      setState(() {
        _linkUrl = link;
      });
      if (link != null) {
        _fetchMetadata(link);
      }
    } else {
      setState(() {});
    }
  }

  Widget _buildLinkPreview(Color backgroundColor, Color foregroundColor) {
    if (_linkUrl == null) return const SizedBox.shrink();

    // Check if this is an audio link
    final isAudioLink = _linkUrl!.startsWith('audio://');

    // Use theme-aware colors for the link preview
    final isDarkBackground = isDark(backgroundColor);
    final previewBgColor = isDarkBackground
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.05);

    // For audio links, find the matching recording by index
    NoteRecording? audioRecording;
    if (isAudioLink) {
      final indexStr = _linkUrl!.substring(8); // Remove 'audio://'
      final index = int.tryParse(indexStr);
      if (index != null) {
        audioRecording = _getRecordingByIndex(index);
      }
    }

    void onTapLink() async {
      if (isAudioLink && audioRecording != null) {
        _scrollToAndPlayAudio(audioRecording.src);
      } else if (!isAudioLink) {
        final uri = Uri.parse(_linkUrl!);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      }
    }

    return Material(
      color: previewBgColor,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: foregroundColor.withValues(alpha: 0.1),
              width: 1,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onTapLink,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      if (isAudioLink)
                        Padding(
                          padding: const EdgeInsets.only(right: 12.0),
                          child: Icon(Icons.audiotrack, color: foregroundColor),
                        )
                      else if (_isLoadingMetadata)
                        Padding(
                          padding: const EdgeInsets.only(right: 12.0),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else if (_linkMetadata?.image != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 12.0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.network(
                              _linkMetadata!.image!,
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(Icons.link, color: foregroundColor),
                            ),
                          ),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(right: 12.0),
                          child: Icon(Icons.link, color: foregroundColor),
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (isAudioLink) ...[
                              Text(
                                audioRecording?.title ?? 'Audio Recording',
                                style: TextStyle(
                                  color: foregroundColor,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                _formatDuration(audioRecording?.length ?? 0),
                                style: TextStyle(
                                  color: foregroundColor.withValues(alpha: 0.8),
                                  fontSize: 12,
                                ),
                              ),
                            ] else ...[
                              Text(
                                _linkMetadata?.title ?? _linkUrl!,
                                style: TextStyle(
                                  color: foregroundColor,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (_linkMetadata?.description != null)
                                Text(
                                  _linkMetadata!.description!,
                                  style: TextStyle(
                                    color: foregroundColor.withValues(
                                      alpha: 0.8,
                                    ),
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              Text(
                                _linkUrl!,
                                style: TextStyle(
                                  color: Colors.blue,
                                  decoration: TextDecoration.underline,
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isAudioLink && audioRecording != null)
              IconButton(
                icon: Icon(
                  Icons.play_circle_outline,
                  size: 24,
                  color: foregroundColor,
                ),
                onPressed: () {
                  _scrollToAndPlayAudio(audioRecording!.src);
                },
              ),
            IconButton(
              icon: Icon(Icons.close, size: 20, color: foregroundColor),
              onPressed: () {
                setState(() {
                  _linkUrl = null;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  void _controllerChangesListener(DocChange event) {
    final lines = _controller.document.toPlainText().split('\n');
    final newTitle = lines.isNotEmpty ? lines.first : null;

    if (newTitle != _title) {
      if (newTitle == null || newTitle.isEmpty) {
        _controller.formatText(0, 0, Attribute.clone(Attribute.h1, null));
      } else {
        _controller.formatText(0, newTitle.length, Attribute.h1);
      }
      _note.title = newTitle ?? '';
      setState(() {
        _title = newTitle ?? '';
      });
    }

    _changeTimer?.cancel();
    _changeTimer = Timer(Duration(seconds: 1), _saveNote);
  }

  Future<void> _saveAsMarkdown() async {
    try {
      // Convert note to markdown
      final markdown = ExportDataService().noteToMarkdown(_note);
      final fileName = _sanitizeFileName(_note.title ?? 'Untitled');
      final markdownBytes = utf8.encode(markdown);

      if (kIsWeb) {
        // On web, use XFile.fromData to trigger download
        await SharePlus.instance.share(
          ShareParams(
            files: [
              XFile.fromData(
                Uint8List.fromList(markdownBytes),
                name: '$fileName.md',
                mimeType: 'text/markdown',
              ),
            ],
          ),
        );
        return;
      }

      // Save to temp directory and share
      final tempDir = await getTemporaryDirectory();
      final filePath = '${tempDir.path}/$fileName.md';
      final file = File(filePath);
      await file.writeAsString(markdown);

      // Share the file
      await SharePlus.instance.share(
        ShareParams(files: [XFile(filePath)], title: '$fileName.md'),
      );
    } catch (e) {
      snackbar('Failed to save: $e', Colors.red);
    }
  }

  String _sanitizeFileName(String name) {
    if (name.isEmpty) return 'untitled';
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .substring(0, name.length > 50 ? 50 : name.length)
        .trim();
  }

  List<PopupMenuEntry> _buildPopupMenu(BuildContext context) {
    bool isSaved = _note.id != null;

    return [
      PopupMenuItem(
        height: 20,
        child: ListTile(leading: Icon(Icons.label), title: Text('Labels')),
        onTap: () async {
          final selectedLabels = await labels(
            context,
            mode: Labels.labelsModeSelect,
            initiallySelected: _note.labels != null
                ? _note.labels!.split(',')
                : [],
          );
          if (selectedLabels != null) {
            _note.labels = selectedLabels.join(',');
            _note.save();
            setState(() {});
          }
        },
      ),
      PopupMenuDivider(),
      PopupMenuItem(
        height: 20,
        child: CheckboxListTile(
          value: _note.archived,
          onChanged: (checked) {
            Navigator.of(context).pop();
            _note.archived = checked ?? false;
            _note.save();
            setState(() {});
          },
          title: Text('Archive'),
        ),
      ),
      PopupMenuItem(
        height: 20,
        child: CheckboxListTile(
          value: _note.readOnly,
          onChanged: (checked) {
            Navigator.of(context).pop();
            _note.readOnly = checked ?? false;
            _controller.readOnly = _note.readOnly;
            _note.save();
            setState(() {});
          },
          title: Text('Read Only'),
        ),
      ),
      PopupMenuItem(
        height: 20,
        child: CheckboxListTile(
          value: _note.locked,
          onChanged: (checked) async {
            Navigator.of(context).pop();

            if (checked == true) {
              // Check entitlement before allowing new lock
              final lockedNotes = await Note.get(NoteType.locked);
              final check = EntitlementGuard.canLockNote(lockedNotes.length);

              if (!check.allowed) {
                // Show paywall when limit reached
                if (context.mounted) {
                  showPaywall(
                    context,
                    feature: GatedFeature.lockNote,
                    customMessage: check.denialReason,
                  );
                }
                return;
              }

              if (!context.mounted) {
                snackbar("Action cancelled", Colors.red);
                return;
              }

              // Locking: show dialog to set password
              final password = await showLockNoteDialog(context);

              if (password == null || password.isEmpty) {
                return;
              }

              try {
                await _note.lock(password);
                if (mounted) {
                  snackbar('Note locked', Colors.green);
                }
              } catch (e) {
                if (mounted) {
                  snackbar('Failed to lock note: $e', Colors.red);
                }
              }
            } else {
              // Removing lock: need password to decrypt before removing lock
              final password =
                  _note.password ?? await showLockNoteDialog(context);
              if (password == null || password.isEmpty) {
                return;
              }
              try {
                await _note.removeLock(password);
                if (mounted) {
                  snackbar('Lock removed', Colors.green);
                }
              } catch (e) {
                if (mounted) {
                  snackbar('Failed to remove lock: $e', Colors.red);
                }
              }
            }
            setState(() {});
          },
          title: Text('Locked'),
        ),
      ),
      PopupMenuDivider(),
      PopupMenuItem(
        height: 20,
        onTap: () => _saveAsMarkdown(),
        child: ListTile(
          leading: Icon(Icons.save_alt),
          title: Text('Save as Markdown'),
        ),
      ),
      PopupMenuItem(
        height: 20,
        onTap: isSaved
            ? () async {
                final duplicatedNote = Note(
                  title: _note.title,
                  content: _note.content,
                  plainText: _note.plainText,
                  labels: _note.labels,
                  color: _note.color,
                  pinned: _note.pinned,
                  archived: _note.archived,
                  locked: _note.locked,
                  readOnly: _note.readOnly,
                  attachments: _note.attachments
                      .map((a) => NoteAttachment.fromJson(a.toJson()))
                      .toList(),
                );
                if (_note.locked &&
                    _note.password != null &&
                    _note.password!.isNotEmpty) {
                  try {
                    await duplicatedNote.lock(_note.password!);
                  } catch (e) {
                    if (mounted) {
                      snackbar(
                        'Note duplicated but failed to lock: $e',
                        Colors.orange,
                      );
                    }
                    return;
                  }
                }
                if (mounted) {
                  snackbar('Note duplicated', Colors.green);
                }
              }
            : null,
        child: ListTile(
          enabled: isSaved,
          leading: Icon(Icons.copy),
          title: Text('Duplicate'),
        ),
      ),
      PopupMenuItem(
        height: 20,
        child: ListTile(
          enabled: isSaved,
          leading: Icon(Icons.delete),
          title: Text('Delete'),
        ),
        onTap: () {
          Navigator.of(context).pop();
          _note.moveToTrash();
        },
      ),
    ];
  }
}
