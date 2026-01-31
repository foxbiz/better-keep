import 'dart:async';
import 'dart:convert';

import 'package:better_keep/components/adaptive_toolbar.dart';
import 'package:better_keep/components/bubble_menu.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/dialogs/audio_recorder_dialog.dart';
import 'package:better_keep/dialogs/checkbox_cascade_dialog.dart';
import 'package:better_keep/dialogs/export_dialog.dart';
import 'package:better_keep/dialogs/paste_dialog.dart';
import 'package:better_keep/dialogs/share_note_dialog.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/content_preview_page.dart';
import 'package:better_keep/pages/note_editor/toolbar/align_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/attach_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/checklist_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/indent_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/link_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/redo_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/style_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/text_color_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/text_size_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/undo_button.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/services/camera_capture.dart';
import 'package:better_keep/services/camera_detection.dart';
import 'package:better_keep/services/checkbox_service.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/ui/paywall/paywall.dart';
import 'package:better_keep/utils/image_compressor.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/components/note_attachments_carousel.dart';
import 'package:better_keep/components/note_audio_player.dart';
import 'package:better_keep/dialogs/color_picker.dart';
import 'package:better_keep/dialogs/labels.dart';
import 'package:better_keep/dialogs/lock_note_dialog.dart';
import 'package:better_keep/dialogs/reminder.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';
import 'package:image_picker/image_picker.dart';
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

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

class _NoteEditorState extends State<NoteEditor>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static final Map<String, Metadata> _metadataCache = {};
  static final Map<String, MemoryImage> _base64ImageCache = {};
  static const int _maxCacheSize = 10;
  static const int _maxImageCacheSize = 50;

  StreamSubscription? _changesSubscription;
  String? _linkUrl;
  Timer? _changeTimer;
  Metadata? _linkMetadata;
  bool _isLoadingMetadata = false;

  final ScrollController _quillScrollController = ScrollController();
  final ScrollController _carouselScrollController = ScrollController();
  final ScrollController _toolbarScrollController = ScrollController();
  final Map<String, GlobalKey> _audioPlayerKeys = {};
  late final Note _note;
  late FocusNode _focusNode;
  late FocusNode _titleFocusNode;
  late TextEditingController _titleController;
  late QuillController _controller;
  late Color _backgroundColor;
  bool _isKeyboardVisible = false;
  String? _initialPlainText;

  // Checkbox cascade/bubble handling
  final CheckboxService _checkboxService = CheckboxService();
  bool _isApplyingCheckboxChanges = false;
  bool _isHandlingCheckboxChange =
      false; // Prevent re-entry while dialog is showing
  // Track offsets that were auto-updated via bubble-up (skip cascade for these)
  final Set<int> _bubbleUpdatedOffsets = {};
  // Track whether to show the attachment FAB (delayed to prevent gesture interruption)
  bool _showAttachmentFab = true;

  /// Handles keyboard events to block formatting shortcuts when editing title
  /// and to handle Backspace at start of content to move focus to title
  KeyEventResult? _handleKeyPressed(KeyEvent event, Node? node) {
    // Only intercept key down events
    if (event is! KeyDownEvent) return null;

    // Handle Backspace at start of content - move focus to title
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      final selection = _controller.selection;
      if (selection.start == 0 && selection.end == 0) {
        // Cursor is at position 0, move focus to title at end
        _titleFocusNode.requestFocus();
        _titleController.selection = TextSelection.collapsed(
          offset: _titleController.text.length,
        );
        return KeyEventResult.handled;
      }
    }

    // Check if we're editing the title
    if (!_titleFocusNode.hasFocus) return null;

    // Check for formatting shortcuts (Cmd/Ctrl + B, I, U)
    final isMetaPressed =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;

    if (isMetaPressed) {
      final key = event.logicalKey;
      // Block bold (Cmd+B), italic (Cmd+I), underline (Cmd+U)
      if (key == LogicalKeyboardKey.keyB ||
          key == LogicalKeyboardKey.keyI ||
          key == LogicalKeyboardKey.keyU) {
        return KeyEventResult.handled;
      }
    }

    return null;
  }

  /// Handles Enter key pressed in title field.
  /// Splits the title at cursor position: keeps text before cursor as title,
  /// moves text after cursor to the beginning of Quill content.
  void _handleTitleEnterPressed() {
    final cursorPos = _titleController.selection.baseOffset;
    final titleText = _titleController.text;

    // If cursor position is invalid or at the end, just move focus
    if (cursorPos < 0 || cursorPos >= titleText.length) {
      _focusNode.requestFocus();
      _controller.updateSelection(
        const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );
      return;
    }

    // Split title at cursor position
    final keepInTitle = titleText.substring(0, cursorPos);
    final moveToContent = titleText.substring(cursorPos);

    // Update title to only keep text before cursor
    _titleController.text = keepInTitle;

    // Insert moved text at the beginning of Quill content
    if (moveToContent.isNotEmpty) {
      _controller.document.insert(0, moveToContent);
    }

    // Move focus to content and position cursor at the start (before inserted text)
    _focusNode.requestFocus();
    _controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
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
    _titleFocusNode = FocusNode(canRequestFocus: true);
    _backgroundColor = _note.color;

    // Parse content and extract title (H1) from Delta JSON
    String initialTitle = '';
    List<dynamic> contentDeltaJson = [];

    if (_note.content != null && _note.content!.isNotEmpty) {
      final parsed = json.decode(_note.content!) as List<dynamic>;

      // Find the H1 header newline operation
      // Check for both '\n' (correct) and '\\n' (legacy corrupted format)
      int h1Index = -1;
      for (int i = 0; i < parsed.length; i++) {
        final op = parsed[i] as Map<String, dynamic>;
        final insert = op['insert'];
        final attrs = op['attributes'] as Map<String, dynamic>?;
        if ((insert == '\n' || insert == '\\n') && attrs?['header'] == 1) {
          h1Index = i;
          break;
        }
      }

      if (h1Index >= 0) {
        // Collect title text from operations before the H1 newline
        final titleBuffer = StringBuffer();
        for (int i = 0; i < h1Index; i++) {
          final op = parsed[i] as Map<String, dynamic>;
          final insert = op['insert'];
          if (insert is String) {
            titleBuffer.write(insert);
          }
        }
        initialTitle = titleBuffer.toString();

        // Content is everything after the H1 newline operation
        contentDeltaJson = parsed.sublist(h1Index + 1);
      } else {
        // No H1 found, use entire content as-is (no title)
        contentDeltaJson = parsed;
      }
    }

    // Create document from remaining content (or empty)
    Document document = contentDeltaJson.isNotEmpty
        ? documentFromJsonSafe(contentDeltaJson)
        : Document();

    // Register custom rules to handle heading reset on new lines before headings
    document.setCustomRules(customQuillRules);

    _titleController = TextEditingController(text: initialTitle);

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

    // Add title change listener for auto-save
    _titleController.addListener(() {
      _changeTimer?.cancel();
      _changeTimer = Timer(Duration(seconds: 1), _saveNote);
    });

    _focusNode.addListener(_focusListener);
    _titleFocusNode.addListener(_titleFocusListener);
    _note.sub("changed", _onNoteChanged);
  }

  void _titleFocusListener() {
    if (!mounted) {
      return;
    }

    if (_titleFocusNode.hasFocus) {
      setState(() {
        _showAttachmentFab = true;
      });
    }
  }

  void _focusListener() {
    if (!mounted) {
      return;
    }

    if (_focusNode.hasFocus) {
      setState(() {
        _showAttachmentFab = false;
      });
    }
  }

  void _onNoteChanged(dynamic _) {
    if (mounted) {
      setState(() {});
    }
  }

  void _scrollToAttachments() {
    // Scroll carousel to end to show the newly added attachment
    // Use a delay to ensure the UI has rebuilt with the new attachment
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted && _carouselScrollController.hasClients) {
        _carouselScrollController.animateTo(
          _carouselScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _appendTranscriptToNote(String text, NoteRecording recording) {
    if (text.isEmpty) return;

    final document = _controller.document;
    final length = document.length;

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
    // Clear checkbox tracking state
    _bubbleUpdatedOffsets.clear();
    _checkboxService.invalidateCache();
    // Pass flag to clear password after save completes (if setting enabled)
    _saveNote(clearPasswordAfterSave: AppState.forgetLockedNotePassword);
    _controller.removeListener(_didChangeSelection);
    _controller.dispose();
    _titleController.dispose();
    _focusNode.dispose();
    _titleFocusNode.dispose();
    _note.unsub("changed", _onNoteChanged);
    _quillScrollController.dispose();
    _carouselScrollController.dispose();
    _toolbarScrollController.dispose();

    _focusNode.removeListener(_focusListener);
    _titleFocusNode.removeListener(_titleFocusListener);

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
    // Guard against empty views on Windows during minimize/display changes
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final bottomInset = views.first.viewInsets.bottom;
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
        floatingActionButton:
            _showAttachmentFab && !_note.readOnly && !_note.trashed
            ? BubbleMenu(
                fabIcon: Icons.attach_file,
                fabSize: 56,
                itemDistance: 100,
                itemSize: 48,
                items: [
                  BubbleMenuItem(
                    icon: Icons.image,
                    label: context.l10n.image,
                    onTap: _showImageSourceDialog,
                  ),
                  BubbleMenuItem(
                    icon: Icons.mic,
                    label: context.l10n.audio,
                    onTap: _handleAudioAttachment,
                  ),
                  BubbleMenuItem(
                    icon: Icons.draw,
                    label: context.l10n.sketch,
                    onTap: _handleSketchAttachment,
                  ),
                ],
              )
            : null,
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
                    tooltip: context.l10n.restore,
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
                    tooltip: context.l10n.reminder,
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
                  IconButton(
                    color: foregroundColor,
                    onPressed: () async {
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
                    icon: Icon(
                      _note.labels != null && _note.labels!.isNotEmpty
                          ? Icons.label
                          : Icons.label_outline,
                    ),
                    tooltip: context.l10n.labels,
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
                      scrollController: _carouselScrollController,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(
                        top: 16,
                        left: 16,
                        right: 16,
                      ),
                      child: Focus(
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.enter) {
                            _handleTitleEnterPressed();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TextField(
                          controller: _titleController,
                          focusNode: _titleFocusNode,
                          autofocus:
                              widget.autoFocus ||
                              (!_note.readOnly && _note.content == ''),
                          readOnly: _note.readOnly || _note.trashed,
                          maxLines: null,
                          keyboardType: TextInputType.text,
                          textInputAction: TextInputAction.next,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w600,
                            color: foregroundColor,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: context.l10n.titleYourThought,
                            hintStyle: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                              color: placeholderColor,
                            ),
                          ),
                        ),
                      ),
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
                            placeholder: context.l10n.startWriting,
                            onKeyPressed: _handleKeyPressed,
                            customLeadingBlockBuilder:
                                customLeadingBlockBuilder,
                            customStyles: buildQuillStyles(
                              foregroundColor: foregroundColor,
                              backgroundColor: backgroundColor,
                              placeholderColor: placeholderColor,
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
                                                    context
                                                        .l10n
                                                        .imageFailedToLoad,
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
                            customLinkPrefixes: const ['audio://'],
                            linkActionPickerDelegate: _audioLinkActionPicker,
                            onLaunchUrl: (url) {
                              return;
                            },
                          ),
                        ),
                      ),
                    ),
                    ..._note.recordings.asMap().entries.map((entry) {
                      final index = entry.key;
                      final recording = entry.value;
                      _audioPlayerKeys[recording.src] ??= GlobalKey();
                      return NoteAudioPlayer(
                        key: _audioPlayerKeys[recording.src],
                        recording: recording,
                        onDelete: () async {
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
            if (!_note.trashed && !_note.readOnly)
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                child: _showAttachmentFab
                    ? const SizedBox.shrink()
                    : _buildToolbar(),
              ),
          ],
        ),
      ),
    );
  }

  /// Maximum image size in bytes (500KB)
  static const int _maxImageSize = 500 * 1024;

  /// Check if attachment limit is reached and show snackbar if so.
  bool _checkAttachmentLimit() {
    if (_note.attachments.length >= maxAttachmentsPerNote) {
      snackbar(
        context.l10n.maxAttachmentsReached(maxAttachmentsPerNote),
        Colors.orange,
      );
      return true;
    }
    return false;
  }

  /// Compresses an image to be under [_maxImageSize] bytes.
  Future<Uint8List> _compressImageToTargetSize(Uint8List imageBytes) async {
    // If already under target, just do a light compression
    if (imageBytes.length <= _maxImageSize) {
      return await ImageCompressor.compressWithList(imageBytes, quality: 90);
    }

    // Start with quality 85 and full size
    int quality = 85;
    int minWidth = 1920;
    int minHeight = 1920;
    Uint8List compressed = imageBytes;

    // Try progressively lower quality first
    while (quality >= 50) {
      compressed = await ImageCompressor.compressWithList(
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
      compressed = await ImageCompressor.compressWithList(
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
    return await ImageCompressor.compressWithList(
      imageBytes,
      quality: 50,
      minWidth: 800,
      minHeight: 800,
    );
  }

  void _showImageSourceDialog() async {
    if (_checkAttachmentLimit()) return;

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

  Future<void> _pickImage(ImageSource source) async {
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
        builder: (context) => PopScope(
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
                    Text(context.l10n.processingImage),
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
      final imagePath = path.join(documentDir, '${Uuid().v4()}$ext');

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
        index: _note.images.length,
        blurredThumbnail: thumbnail,
      );

      _note.addImage(noteImage);
      _scrollToAttachments();
    } finally {
      // Dismiss loading dialog
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    }
  }

  void _handleAudioAttachment() async {
    if (_checkAttachmentLimit()) return;

    final result = await showDialog<AudioRecordingResult>(
      context: context,
      builder: (context) => const AudioRecorderDialog(),
    );

    if (result != null && mounted) {
      _note.addRecording(
        NoteRecording(
          src: result.path,
          title: result.title,
          length: result.length,
          transcript: result.transcription,
        ),
      );
      _scrollToAttachments();
      // Append transcription to note if provided
      if (result.transcription != null && result.transcription!.isNotEmpty) {
        final recording = NoteRecording(
          src: result.path,
          title: result.title,
          length: result.length,
          transcript: result.transcription,
        );
        _appendTranscriptToNote(result.transcription!, recording);
      }
      // Set note title from first few words if note has no title
      if (_titleController.text.isEmpty &&
          result.transcription != null &&
          result.transcription!.isNotEmpty) {
        final words = result.transcription!
            .split(' ')
            .where((w) => w.isNotEmpty)
            .toList();
        if (words.isNotEmpty) {
          final titleWords = words.take(5).join(' ');
          _titleController.text = titleWords + (words.length > 5 ? '...' : '');
        }
      }
    }
  }

  void _handleSketchAttachment() async {
    if (_checkAttachmentLimit()) return;

    await showPage(
      context,
      SketchPage(
        note: _note,
        sketch: SketchData(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
    );
    _scrollToAttachments();
  }

  Widget _buildToolbar() {
    final noteColor = _note.color;
    Color textColor = isDark(noteColor) ? Colors.white : Colors.black;
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;

    return AdaptiveToolbar(
      key: Key('note_editor_toolbar'),
      parentColor: noteColor,
      scrollController: _toolbarScrollController,
      children: [
        if (isIOS)
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: _isKeyboardVisible
                ? IconButton(
                    icon: const Icon(Icons.keyboard_hide),
                    onPressed: () => _focusNode.unfocus(),
                    tooltip: context.l10n.hideKeyboard,
                  )
                : const SizedBox.shrink(),
          ),
        UndoButton(
          readOnly: _note.readOnly,
          controller: _controller,
          focusNode: _focusNode,
        ),
        RedoButton(
          readOnly: _note.readOnly,
          controller: _controller,
          focusNode: _focusNode,
        ),
        AttachButton(
          readOnly: _note.readOnly,
          note: _note,
          onAppendTranscript: _appendTranscriptToNote,
          onAttachmentAdded: _scrollToAttachments,
        ),
        TextColorButton(
          color: textColor,
          focusNode: _focusNode,
          readOnly: _note.readOnly,
          controller: _controller,
        ),
        CheckListButton(
          focusNode: _focusNode,
          controller: _controller,
          readOnly: _note.readOnly,
        ),
        LinkButton(controller: _controller, readOnly: _note.readOnly),
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
        ),
        IndentButton(
          focusNode: _focusNode,
          controller: _controller,
          readOnly: _note.readOnly,
        ),
        TextSizeButton(
          focusNode: _focusNode,
          controller: _controller,
          readOnly: _note.readOnly,
        ),
      ],
    );
  }

  Widget _styleButton(Attribute attribute) {
    return StyleButton(
      attribute: attribute,
      focusNode: _focusNode,
      controller: _controller,
      readOnly: _note.readOnly,
    );
  }

  void _saveNote({bool clearPasswordAfterSave = false}) async {
    // Update note title from title controller
    final title = _titleController.text;
    _note.title = title;

    // Create a combined delta with title as first line (h1) + content
    final contentDelta = _controller.document.toDelta().toJson();
    final combinedDeltaJson = <Map<String, dynamic>>[];

    // Add title as h1 if not empty
    if (title.isNotEmpty) {
      combinedDeltaJson.add({'insert': title});
      combinedDeltaJson.add({
        'insert': '\n',
        'attributes': {'header': 1},
      });
    }

    // Add content delta operations
    combinedDeltaJson.addAll(List<Map<String, dynamic>>.from(contentDelta));

    // If deleteIfUnchanged is set and content hasn't meaningfully changed, delete instead of save
    if (widget.deleteIfUnchanged && _initialPlainText != null) {
      final combinedDoc = documentFromJsonSafe(combinedDeltaJson);
      final currentPlainText = combinedDoc.toPlainText().trim();
      if (currentPlainText == _initialPlainText) {
        try {
          await _note.delete();
        } catch (e) {
          AppLogger.error('Error deleting unchanged note', e);
        }
        return;
      }
    }

    final contentPlainText = _controller.document.toPlainText().trim();
    final isEmpty = title.isEmpty && contentPlainText.isEmpty;

    if (_note.isEmpty && isEmpty) {
      try {
        await _note.delete();
      } catch (e) {
        AppLogger.error('Error saving note', e);
        snackbar(context.l10n.errorSavingNote, Colors.red);
      }
      return;
    }

    final oldContent = _note.content;
    final newContent = json.encode(combinedDeltaJson);

    if (oldContent == newContent) {
      // Even if content unchanged, clear password if requested
      if (clearPasswordAfterSave && _note.locked) {
        _note.clearPassword();
      }
      return;
    }

    try {
      // Get plain text from combined document
      final combinedDoc = documentFromJsonSafe(combinedDeltaJson);
      final plainText = combinedDoc.toPlainText().trim();
      await _note.setContent(newContent, plainText);
      // Clear password after successful save if setting is enabled
      if (clearPasswordAfterSave && _note.locked) {
        _note.clearPassword();
      }
    } catch (e) {
      AppLogger.error('Error saving note', e);
      snackbar(context.l10n.errorSavingNote, Colors.red);
    }
  }

  Widget _toolNoteColor(Color noteColor, Color iconColor) {
    return IconButton(
      icon: Icon(Icons.color_lens),
      color: iconColor,
      onPressed: () async {
        _focusNode.unfocus();
        final color = await colorPicker(
          context,
          context.l10n.pickNoteColor,
          noteColor,
        );
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
                                audioRecording?.title ??
                                    context.l10n.audioRecording,
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
    // Always set the save timer for any document change (including cascade/bubble)
    _changeTimer?.cancel();
    _changeTimer = Timer(Duration(seconds: 1), _saveNote);

    // Skip checkbox processing if we're applying checkbox cascade/bubble changes
    if (_isApplyingCheckboxChanges) return;

    // Handle nested checkbox cascade/bubble logic
    // Fire-and-forget with error handling
    _handleCheckboxChange(event).catchError((error) {
      // Log error but don't crash - checkbox cascade is non-critical
      debugPrint('Checkbox cascade error: $error');
    });
  }

  /// Handle nested checkbox cascade (parent→children) and bubble (children→parent) logic
  Future<void> _handleCheckboxChange(DocChange event) async {
    // Prevent re-entry while dialog is showing or changes are being applied
    if (_isHandlingCheckboxChange || _isApplyingCheckboxChanges) return;

    // Detect if a checkbox was toggled
    final changeResult = _checkboxService.detectChange(
      event.before,
      event.change,
    );

    if (changeResult == null) return;

    _isHandlingCheckboxChange = true;
    try {
      // Parse the checkbox tree
      final nodes = _checkboxService.parseCheckboxTree(_controller.document);
      if (nodes.isEmpty) return;

      // Find the node that was changed
      final nodeIndex = _checkboxService.getNodeIndexAtOffset(
        changeResult.offset,
      );
      if (nodeIndex == null) return;

      final isChecking = changeResult.isChecked;

      // Check if this checkbox was auto-updated via bubble-up
      // If so, skip cascade confirmation (it was an indirect update)
      final wasBubbleUpdated = _bubbleUpdatedOffsets.remove(
        changeResult.offset,
      );

      if (!wasBubbleUpdated) {
        // Check for cascade (parent has children that need updating)
        final cascadeTargets = _checkboxService.getCascadeTargets(
          nodeIndex,
          isChecking,
          nodes,
        );

        if (cascadeTargets.isNotEmpty && mounted) {
          // Show confirmation dialog
          final confirmed = await showCheckboxCascadeDialog(
            context,
            isChecking: isChecking,
            affectedCount: cascadeTargets.length,
          );

          // Check mounted after async gap
          if (!mounted) return;

          if (confirmed) {
            // Re-parse tree in case document changed while dialog was showing
            final freshNodes = _checkboxService.parseCheckboxTree(
              _controller.document,
            );
            final freshNodeIndex = _checkboxService.getNodeIndexAtOffset(
              changeResult.offset,
            );

            if (freshNodeIndex != null) {
              final freshCascadeTargets = _checkboxService.getCascadeTargets(
                freshNodeIndex,
                isChecking,
                freshNodes,
              );

              // Apply cascade changes
              _isApplyingCheckboxChanges = true;
              try {
                _checkboxService.applyCheckboxChanges(
                  _controller,
                  freshCascadeTargets,
                  isChecking,
                );
              } finally {
                _isApplyingCheckboxChanges = false;
              }
            }
          } else {
            // User cancelled - revert the parent checkbox
            _isApplyingCheckboxChanges = true;
            try {
              _controller.formatText(
                changeResult.offset,
                0,
                changeResult.wasChecked
                    ? Attribute.checked
                    : Attribute.unchecked,
              );
              _checkboxService.invalidateCache();
            } finally {
              _isApplyingCheckboxChanges = false;
            }
            return; // Don't proceed with bubble logic
          }
        }
      }

      // Check mounted before bubble logic
      if (!mounted) return;

      // Check for bubble (all siblings checked → check parent, or any sibling unchecked → uncheck parent)
      // Re-parse the tree after potential cascade changes
      final updatedNodes = _checkboxService.parseCheckboxTree(
        _controller.document,
      );
      final updatedNodeIndex = _checkboxService.getNodeIndexAtOffset(
        changeResult.offset,
      );

      if (updatedNodeIndex != null) {
        final bubbleTargets = _checkboxService.getBubbleTargets(
          updatedNodeIndex,
          isChecking,
          updatedNodes,
        );

        if (bubbleTargets.isNotEmpty) {
          _isApplyingCheckboxChanges = true;
          try {
            for (final target in bubbleTargets) {
              // Track this offset as auto-updated via bubble-up
              // Limit set size to prevent memory leak from stale offsets
              if (_bubbleUpdatedOffsets.length > 100) {
                _bubbleUpdatedOffsets.clear();
              }
              _bubbleUpdatedOffsets.add(target.offset);
              _controller.formatText(
                target.offset,
                0,
                target.newState ? Attribute.checked : Attribute.unchecked,
              );
            }
            _checkboxService.invalidateCache();
          } finally {
            _isApplyingCheckboxChanges = false;
          }
        }
      }
    } finally {
      _isHandlingCheckboxChange = false;
      // DON'T clear _bubbleUpdatedOffsets here!
      // Stream events are async - bubble updates trigger listener calls AFTER this finally block.
      // The .remove() call in wasBubbleUpdated handles cleanup.
      // Full clear only happens in dispose().
    }
  }

  /// Handles the "Paste as" menu action with proper mounted checks
  Future<void> _handlePasteAs(BuildContext context) async {
    // Capture navigator before async gap to avoid using stale context
    final navigator = Navigator.of(context);

    final result = await showPasteOptions(context);

    if (!mounted) return;

    switch (result) {
      case PasteCancelled():
        // User cancelled, do nothing
        break;

      case PastePlainText(:final text):
        try {
          insertPlainTextIntoController(_controller, text);
          snackbar(context.l10n.pastedAsPlainText, Colors.green);
        } catch (e) {
          snackbar(context.l10n.failedToPaste(e.toString()), Colors.red);
        }
        break;

      case PasteFormattedPreview(:final markdownText):
        // Navigate to preview page using captured navigator
        final document = await navigator.push<Document>(
          MaterialPageRoute(
            builder: (context) => ContentPreviewPage(
              title: context.l10n.pastedContent,
              content: markdownText,
              isMarkdown: true,
              insertMode: true,
            ),
          ),
        );

        if (!mounted) return;

        if (document != null) {
          try {
            insertDocumentIntoController(_controller, document);
            snackbar(context.l10n.contentInserted, Colors.green);
          } catch (e) {
            snackbar(
              context.l10n.failedToInsertContent(e.toString()),
              Colors.red,
            );
          }
        }
        break;
    }
  }

  List<PopupMenuEntry> _buildPopupMenu(BuildContext context) {
    bool isSaved = _note.id != null;

    return [
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
          title: Text(context.l10n.archive),
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
          title: Text(context.l10n.readOnly),
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
              final check = EntitlementGuard.canLockNote(
                lockedNotes.length,
                context.l10n,
              );

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
                snackbar(context.l10n.actionCancelled, Colors.red);
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
                  snackbar(context.l10n.noteLocked, Colors.green);
                }
              } catch (e) {
                if (mounted) {
                  snackbar(
                    context.l10n.failedToLockNote(e.toString()),
                    Colors.red,
                  );
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
                  snackbar(context.l10n.lockRemoved, Colors.green);
                }
              } catch (e) {
                if (mounted) {
                  snackbar(
                    context.l10n.failedToRemoveLock(e.toString()),
                    Colors.red,
                  );
                }
              }
            }
            setState(() {});
          },
          title: Text(context.l10n.locked),
        ),
      ),
      PopupMenuDivider(),
      PopupMenuItem(
        height: 20,
        onTap: () => showExportOptions(context, _note, _controller),
        child: ListTile(
          leading: Icon(Icons.save_alt),
          title: Text(context.l10n.saveAs),
        ),
      ),
      PopupMenuItem(
        height: 20,
        onTap: () => showCopyOptions(context, _note, _controller),
        child: ListTile(
          leading: Icon(Icons.content_copy),
          title: Text(context.l10n.copyAs),
        ),
      ),
      PopupMenuItem(
        height: 20,
        onTap: () => _handlePasteAs(context),
        child: ListTile(
          leading: Icon(Icons.paste),
          title: Text(context.l10n.pasteAs),
        ),
      ),
      PopupMenuItem(
        height: 20,
        onTap: () => showShareNoteDialog(context, _note),
        child: ListTile(
          leading: Icon(Icons.share),
          title: Text(context.l10n.share),
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
                        context.l10n.noteDuplicatedButFailedToLock(
                          e.toString(),
                        ),
                        Colors.orange,
                      );
                    }
                    return;
                  }
                }
                if (mounted) {
                  snackbar(context.l10n.noteDuplicated, Colors.green);
                }
              }
            : null,
        child: ListTile(
          enabled: isSaved,
          leading: Icon(Icons.copy),
          title: Text(context.l10n.duplicate),
        ),
      ),
      PopupMenuItem(
        height: 20,
        child: ListTile(
          enabled: isSaved,
          leading: Icon(Icons.delete),
          title: Text(context.l10n.delete),
        ),
        onTap: () {
          Navigator.of(context).pop();
          _note.moveToTrash();
        },
      ),
    ];
  }
}
