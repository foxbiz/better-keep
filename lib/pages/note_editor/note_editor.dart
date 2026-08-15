import 'dart:async';
import 'dart:convert';

import 'package:better_keep/components/bubble_menu.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/dialogs/audio_recorder_dialog.dart';
import 'package:better_keep/dialogs/attachment_commit_dialog.dart';
import 'package:better_keep/dialogs/checkbox_cascade_dialog.dart';
import 'package:better_keep/dialogs/export_dialog.dart';
import 'package:better_keep/dialogs/paste_dialog.dart';
import 'package:better_keep/dialogs/share_note_dialog.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/rich_checklist.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/checklist_editor/rich_checklist_editor.dart';
import 'package:better_keep/pages/content_preview_page.dart';
import 'package:better_keep/pages/note_editor/checklist_caret_prompt_controller.dart';
import 'package:better_keep/pages/note_editor/note_editor_action_service.dart';
import 'package:better_keep/pages/note_editor/note_editor_app_bar.dart';
import 'package:better_keep/pages/note_editor/note_editor_toolbar.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/services/camera_capture.dart';
import 'package:better_keep/services/camera_detection.dart';
import 'package:better_keep/services/checklist_delta_codec.dart';
import 'package:better_keep/services/checkbox_service.dart';
import 'package:better_keep/services/due_reminder_presenter.dart';
import 'package:better_keep/services/image_attachment_preparation_service.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/reminder_schedule_result_presenter.dart';
import 'package:better_keep/services/review_prompt_service.dart';
import 'package:better_keep/ui/paywall/paywall.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:better_keep/utils/quill_image_utils.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/components/note_attachments_carousel.dart';
import 'package:better_keep/components/note_audio_player.dart';
import 'package:better_keep/dialogs/color_picker.dart';
import 'package:better_keep/dialogs/labels.dart';
import 'package:better_keep/dialogs/lock_note_dialog.dart';
import 'package:better_keep/dialogs/reminder.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';
import 'package:image_picker/image_picker.dart';
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';

class NoteEditor extends StatefulWidget {
  final Note? note;
  final bool autoFocus;
  final bool deleteIfUnchanged;
  final ImageAttachmentPreparationService? imageAttachmentPreparationService;
  const NoteEditor({
    super.key,
    this.note,
    this.autoFocus = false,
    this.deleteIfUnchanged = false,
    this.imageAttachmentPreparationService,
  });

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

@immutable
class _ChecklistPopupGeometry {
  const _ChecklistPopupGeometry({
    required this.left,
    required this.top,
    required this.width,
  });

  final double left;
  final double top;
  final double width;
}

class _NoteEditorState extends State<NoteEditor>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static final Map<String, Metadata> _metadataCache = {};
  static const int _maxCacheSize = 10;

  StreamSubscription? _changesSubscription;
  String? _linkUrl;
  Timer? _changeTimer;
  Timer? _checklistEligibilityTimer;
  Timer? _checklistLayoutRetryTimer;
  final Set<String> _shownDueReminderOccurrences = <String>{};
  final ChecklistDeltaCodec _checklistDeltaCodec = ChecklistDeltaCodec();
  final ChecklistCaretPromptController _checklistPromptController =
      ChecklistCaretPromptController();
  final ValueNotifier<({int checked, int total})> _checklistProgress =
      ValueNotifier((checked: 0, total: 0));
  Future<void> _saveTail = Future<void>.value();
  Future<void>? _pendingLockOperation;
  Future<void>? _pendingLockRemovalOperation;
  bool _isLockQueued = false;
  bool _isLockRemovalQueued = false;
  bool _isClosing = false;
  bool _allowPop = false;
  Metadata? _linkMetadata;
  bool _isLoadingMetadata = false;

  final ScrollController _quillScrollController = ScrollController();
  final ScrollController _carouselScrollController = ScrollController();
  final ScrollController _toolbarScrollController = ScrollController();
  final Map<String, GlobalKey> _audioPlayerKeys = {};
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();
  final GlobalKey _editorStackKey = GlobalKey();
  late final Note _note;
  late FocusNode _focusNode;
  late FocusNode _titleFocusNode;
  late TextEditingController _titleController;
  late QuillController _controller;
  late Color _backgroundColor;
  bool _isKeyboardVisible = false;
  String? _initialPlainText;
  bool _checklistLayoutSyncScheduled = false;
  _ChecklistPopupGeometry? _checklistPopupGeometry;

  // Checkbox cascade/bubble handling
  final CheckboxService _checkboxService = CheckboxService();
  bool _isApplyingCheckboxChanges = false;
  bool _isHandlingCheckboxChange =
      false; // Prevent re-entry while dialog is showing
  // Track offsets that were auto-updated via bubble-up (skip cascade for these)
  final Set<int> _bubbleUpdatedOffsets = {};
  // Track whether to show the attachment FAB (delayed to prevent gesture interruption)
  bool _showAttachmentFab = true;
  // Timers for scroll-to-caret (cancelled on dispose or new scroll request)
  final List<Timer> _scrollTimers = [];

  /// Handles keyboard events to block formatting shortcuts when editing title
  /// and to handle Backspace at start of content to move focus to title
  KeyEventResult _handleKeyPressed(FocusNode node, KeyEvent event) {
    // Only intercept key down events
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Handle Backspace at start of content
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      final selection = _controller.selection;
      if (selection.start == 0 && selection.end == 0) {
        final document = _controller.document;
        final docLength = document.length;

        // Check if document is empty (only contains the trailing newline)
        if (docLength <= 1) {
          // Document is empty, move focus to title at end
          _titleFocusNode.requestFocus();
          _titleController.selection = TextSelection.collapsed(
            offset: _titleController.text.length,
          );
          return KeyEventResult.handled;
        }

        // Check if first line is empty (starts with newline)
        final plainText = document.toPlainText();
        final firstChar = plainText.isNotEmpty ? plainText[0] : '';
        if (firstChar == '\n') {
          // First line is empty, delete it and stay in editor
          _controller.replaceText(0, 1, '', null);
          _controller.updateSelection(
            const TextSelection.collapsed(offset: 0),
            ChangeSource.local,
          );
          return KeyEventResult.handled;
        }

        // First line has content, move focus to title at end
        _titleFocusNode.requestFocus();
        _titleController.selection = TextSelection.collapsed(
          offset: _titleController.text.length,
        );
        return KeyEventResult.handled;
      }
    }

    // Check if we're editing the title
    if (!_titleFocusNode.hasFocus) return KeyEventResult.ignored;

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

    return KeyEventResult.ignored;
  }

  /// Handles Enter key pressed in title field.
  /// Moves focus to the Quill content editor at the start.
  void _handleTitleEnterPressed() {
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
    _updateChecklistProgress();
    _refreshChecklistEligibility(rebuild: false);

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
      _scheduleAutosave();
    });

    _focusNode.addListener(_focusListener);
    _titleFocusNode.addListener(_titleFocusListener);
    _checklistPromptController.addListener(_onChecklistPromptChanged);
    _checklistPromptController.updateInteraction(
      hasFocus: _focusNode.hasFocus,
      hasCollapsedSelection: _hasCollapsedChecklistSelection,
    );
    _quillScrollController.addListener(_requestChecklistPopupLayout);
    _note.sub("changed", _onNoteChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showOverdueReminderDialogIfNeeded());
    });
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

    _checklistPromptController.updateInteraction(
      hasFocus: _focusNode.hasFocus,
      hasCollapsedSelection: _hasCollapsedChecklistSelection,
    );
    if (_focusNode.hasFocus) {
      setState(() {
        _showAttachmentFab = false;
      });

      // Scroll to caret after toolbar animation completes
      _scrollToCaretAfterKeyboard();
    } else {
      _checklistLayoutRetryTimer?.cancel();
      setState(() {});
    }
    _scheduleChecklistPopupLayout();
  }

  void _refreshChecklistEligibility({bool rebuild = true}) {
    _checklistPromptController.updateBlock(_checklistBlockAtCaret);
    if (rebuild && mounted) setState(() {});
    _scheduleChecklistPopupLayout(resetAttempts: false);
  }

  void _scheduleChecklistEligibilityRefresh() {
    _checklistEligibilityTimer?.cancel();
    _checklistEligibilityTimer = Timer(
      const Duration(milliseconds: 120),
      _refreshChecklistEligibility,
    );
  }

  bool get _hasCollapsedChecklistSelection =>
      _controller.selection.isValid && _controller.selection.isCollapsed;

  ChecklistBlockLookupResult? get _checklistBlockAtCaret {
    if (!_hasCollapsedChecklistSelection) return null;
    final lookup = _checklistDeltaCodec.findChecklistBlockAt(
      _controller.document,
      _controller.selection.baseOffset,
    );
    return lookup.isChecklistLine ? lookup : null;
  }

  void _onChecklistPromptChanged() {
    if (!mounted) return;
    if (!_checklistPromptController.state.isVisible) {
      _checklistPopupGeometry = null;
    }
    setState(() {});
  }

  void _scheduleChecklistPopupLayout({bool resetAttempts = true}) {
    if (!mounted) return;
    if (resetAttempts) _checklistPromptController.requestLayout();
    if (!_checklistPromptController.state.needsLayout ||
        _checklistLayoutSyncScheduled) {
      return;
    }
    _checklistLayoutSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checklistLayoutSyncScheduled = false;
      if (mounted) _syncChecklistPopupLayout();
    });
  }

  void _syncChecklistPopupLayout() {
    if (!_checklistPromptController.state.needsLayout) return;
    final geometry = _resolveChecklistPopupGeometry();
    if (geometry == null) {
      final shouldRetry = _checklistPromptController.markLayoutUnavailable();
      if (shouldRetry) {
        final attempt = _checklistPromptController.state.layoutAttempts;
        _checklistLayoutRetryTimer?.cancel();
        _checklistLayoutRetryTimer = Timer(
          Duration(milliseconds: 16 + (attempt * 24)),
          () => _scheduleChecklistPopupLayout(resetAttempts: false),
        );
      }
      return;
    }
    _checklistPopupGeometry = geometry;
    _checklistLayoutRetryTimer?.cancel();
    _checklistPromptController.markLayoutReady();
  }

  void _dismissChecklistPopup() {
    _checklistLayoutRetryTimer?.cancel();
    _checklistPopupGeometry = null;
    _checklistPromptController.dismissUntilNextTap();
  }

  void _requestChecklistPopupLayout() {
    _scheduleChecklistPopupLayout();
  }

  _ChecklistPopupGeometry? _resolveChecklistPopupGeometry() {
    final editorState = _editorKey.currentState;
    final stackRenderObject = _editorStackKey.currentContext
        ?.findRenderObject();
    if (editorState == null ||
        !_checklistPromptController.state.needsLayout ||
        stackRenderObject is! RenderBox ||
        !stackRenderObject.attached ||
        !stackRenderObject.hasSize) {
      return null;
    }

    try {
      final renderEditor = editorState.renderEditor;
      final selection = _controller.selection;
      if (!renderEditor.attached ||
          !selection.isValid ||
          !selection.isCollapsed) {
        return null;
      }
      final caretRect = renderEditor.getLocalRectForCaret(
        TextPosition(offset: selection.baseOffset),
      );
      final caretTop = stackRenderObject.globalToLocal(
        renderEditor.localToGlobal(caretRect.topLeft),
      );
      final media = MediaQuery.of(context);
      final availableWidth = stackRenderObject.size.width - 16;
      if (availableWidth < 120) return null;
      final popupWidth = availableWidth.clamp(120.0, 280.0).toDouble();
      final left = (caretTop.dx - 14)
          .clamp(8.0, stackRenderObject.size.width - popupWidth - 8)
          .toDouble();
      final safeTop = media.padding.top + 8;
      final top = (caretTop.dy - 56)
          .clamp(
            safeTop,
            stackRenderObject.size.height - media.padding.bottom - 56,
          )
          .toDouble();
      return _ChecklistPopupGeometry(left: left, top: top, width: popupWidth);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[ChecklistPrompt] caret geometry unavailable: '
          '${error.runtimeType}',
        );
      }
      return null;
    }
  }

  Widget _buildChecklistPopup() {
    final geometry = _checklistPopupGeometry;
    if (geometry == null || !_checklistPromptController.state.isVisible) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: geometry.left,
      top: geometry.top,
      width: geometry.width,
      child: Material(
        key: const ValueKey('open_focused_checklist_popup'),
        elevation: 8,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shadowColor: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                key: const ValueKey('open_focused_checklist'),
                onTap: _openFocusedChecklistEditor,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 8, 12),
                  child: Row(
                    children: [
                      const Icon(Icons.view_list_rounded, size: 20),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          context.l10n.openChecklistView,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('dismiss_focused_checklist_popup'),
              onPressed: _dismissChecklistPopup,
              icon: const Icon(Icons.close, size: 18),
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            ),
          ],
        ),
      ),
    );
  }

  void _handleChecklistEditorTap() {
    _checklistPromptController.onEditorTap(
      block: _checklistBlockAtCaret,
      hasFocus: _focusNode.hasFocus,
      hasCollapsedSelection: _hasCollapsedChecklistSelection,
    );
    // Quill resolves the tapped line after pointer down. Evaluate on the next
    // frame so a tap can never open the block at the previous caret position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final block = _checklistBlockAtCaret;
      _checklistPromptController.onEditorTap(
        block: block,
        hasFocus: _focusNode.hasFocus,
        hasCollapsedSelection: _hasCollapsedChecklistSelection,
      );
      if (block?.isEligible ?? false) {
        _checklistPromptController.requestLayout();
        _syncChecklistPopupLayout();
      } else if (block?.isChecklistLine ?? false) {
        _showFocusedChecklistEligibilityGuidance(block?.failureReason);
      }
    });
  }

  void _showFocusedChecklistEligibilityGuidance(
    ChecklistDeltaFailureReason? reason,
  ) {
    final message = switch (reason) {
      ChecklistDeltaFailureReason.nonChecklistLine ||
      ChecklistDeltaFailureReason.empty ||
      ChecklistDeltaFailureReason.noItems ||
      ChecklistDeltaFailureReason.unterminatedLine =>
        context.l10n.focusedChecklistInvalidContent,
      ChecklistDeltaFailureReason.embed ||
      ChecklistDeltaFailureReason.textBlockAttributes ||
      ChecklistDeltaFailureReason.incompatibleBlock =>
        context.l10n.focusedChecklistUnsupportedContent,
      _ => context.l10n.focusedChecklistInvalidContent,
    };
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openFocusedChecklistEditor() async {
    _changeTimer?.cancel();
    final previousSelection = _controller.selection;
    final selectedBlock = _checklistBlockAtCaret?.slice;
    _dismissChecklistPopup();
    if (selectedBlock == null) return;
    _focusNode.unfocus();
    if (!_note.readOnly && !_note.trashed && !await _enqueueSave()) return;
    if (!mounted) return;

    final session = _checklistDeltaCodec.createEditSession(
      title: _titleController.text,
      document: _controller.document,
      caretOffset: previousSelection.baseOffset,
      selectionStart: previousSelection.start,
      selectionEnd: previousSelection.end,
    );
    if (session == null) {
      snackbar(context.l10n.somethingWentWrongTryAgain, Colors.orange);
      _refreshChecklistEligibility();
      return;
    }

    final result = await Navigator.of(context).push<RichChecklistEditorResult>(
      MaterialPageRoute(
        builder: (_) => RichChecklistEditor(note: _note, session: session),
      ),
    );
    if (!mounted || result is! RichChecklistEditorResult) return;
    await _applyChecklistEditorResult(result, previousSelection);
  }

  Future<void> _openChecklistCollectionEditor() async {
    _changeTimer?.cancel();
    final previousSelection = _controller.selection;
    _dismissChecklistPopup();
    _focusNode.unfocus();
    if (!_note.readOnly && !_note.trashed && !await _enqueueSave()) return;
    if (!mounted) return;

    final session = _checklistDeltaCodec.createCollectionEditSession(
      title: _titleController.text,
      document: _controller.document,
      selectionStart: previousSelection.start,
      selectionEnd: previousSelection.end,
    );
    if (session == null) return;

    final result = await Navigator.of(context)
        .push<RichChecklistCollectionEditorResult>(
          MaterialPageRoute(
            builder: (_) =>
                RichChecklistCollectionEditor(note: _note, session: session),
          ),
        );
    if (!mounted || result == null) return;
    await _applyChecklistCollectionEditorResult(result, previousSelection);
  }

  Future<void> _applyChecklistEditorResult(
    RichChecklistEditorResult result,
    TextSelection previousSelection,
  ) async {
    final previousChangesSubscription = _changesSubscription;
    _changesSubscription = null;
    unawaited(previousChangesSubscription?.cancel());
    if (!mounted) return;
    final currentBody = _controller.document.toDelta();
    final currentSlice = currentBody
        .slice(
          result.replacementStart,
          result.replacementStart + result.replacementLength,
        )
        .toJson();
    final maxSelectionOffset =
        documentFromJsonSafe(result.bodyDelta).length - 1;
    final restoredSelection = TextSelection(
      baseOffset: result.selectionStart.clamp(0, maxSelectionOffset),
      extentOffset: result.selectionEnd.clamp(0, maxSelectionOffset),
      affinity: previousSelection.affinity,
      isDirectional: previousSelection.isDirectional,
    );
    if (!result.requiresFullRefresh &&
        _checklistDeltaCodec.fingerprintOperations(currentSlice) ==
            result.sourceFingerprint) {
      final transaction = Delta()..retain(result.replacementStart);
      for (final operation in Delta.fromJson(
        result.replacementDelta,
      ).toList()) {
        transaction.push(operation);
      }
      transaction.delete(result.replacementLength);
      _controller.compose(transaction, restoredSelection, ChangeSource.local);
      _controller.updateSelection(restoredSelection, ChangeSource.local);
    } else {
      final document = documentFromJsonSafe(result.bodyDelta);
      document.setCustomRules(customQuillRules);
      _controller.document = document;
      _controller.updateSelection(restoredSelection, ChangeSource.local);
    }
    _changesSubscription = _controller.changes.listen(
      _controllerChangesListener,
    );
    if (_titleController.text != result.title) {
      _titleController.text = result.title;
    }
    _note
      ..title = result.title
      ..content = result.content
      ..plainText = result.plainText;
    _checkboxService.invalidateCache();
    _updateChecklistProgress();
    _checklistPromptController.updateBlock(null);
    if (mounted) setState(() {});
  }

  Future<void> _applyChecklistCollectionEditorResult(
    RichChecklistCollectionEditorResult result,
    TextSelection previousSelection,
  ) async {
    final previousChangesSubscription = _changesSubscription;
    _changesSubscription = null;
    unawaited(previousChangesSubscription?.cancel());
    if (!mounted) return;
    final maxSelectionOffset =
        documentFromJsonSafe(result.bodyDelta).length - 1;
    final restoredSelection = TextSelection(
      baseOffset: result.selectionStart.clamp(0, maxSelectionOffset),
      extentOffset: result.selectionEnd.clamp(0, maxSelectionOffset),
      affinity: previousSelection.affinity,
      isDirectional: previousSelection.isDirectional,
    );
    var appliedTransaction = false;
    if (!result.requiresFullRefresh) {
      try {
        final transaction = _checklistDeltaCodec.buildCollectionTransaction(
          currentBodyDelta: _controller.document.toDelta().toJson(),
          replacements: result.replacements,
        );
        if (transaction.isNotEmpty) {
          _controller.compose(
            transaction,
            restoredSelection,
            ChangeSource.local,
          );
        }
        _controller.updateSelection(restoredSelection, ChangeSource.local);
        appliedTransaction = true;
      } on ChecklistBlockStaleException {
        appliedTransaction = false;
      }
    }
    if (!appliedTransaction) {
      final document = documentFromJsonSafe(result.bodyDelta);
      document.setCustomRules(customQuillRules);
      _controller.document = document;
      _controller.updateSelection(restoredSelection, ChangeSource.local);
    }
    _changesSubscription = _controller.changes.listen(
      _controllerChangesListener,
    );
    if (_titleController.text != result.title) {
      _titleController.text = result.title;
    }
    _note
      ..title = result.title
      ..content = result.content
      ..plainText = result.plainText;
    _checkboxService.invalidateCache();
    _updateChecklistProgress();
    _checklistPromptController.updateBlock(null);
    if (mounted) setState(() {});
  }

  /// Scrolls the editor to ensure the caret is visible above the toolbar
  void _scrollToCaret() {
    if (!mounted || !_focusNode.hasFocus) return;

    final editorState = _editorKey.currentState;
    if (editorState == null) return;

    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return;

    try {
      final renderEditor = editorState.renderEditor;
      final caretRect = renderEditor.getLocalRectForCaret(
        TextPosition(offset: selection.baseOffset),
      );

      // Convert caret position to global coordinates
      final caretGlobal = renderEditor.localToGlobal(caretRect.bottomLeft);

      // Get screen height and keyboard insets directly
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return;
      final view = views.first;
      final screenHeight = view.physicalSize.height / view.devicePixelRatio;
      final keyboardHeight = view.viewInsets.bottom / view.devicePixelRatio;

      // Get the scroll view's position on screen
      if (!_quillScrollController.hasClients) return;
      final scrollPosition = _quillScrollController.position;

      // Toolbar height estimate (toolbar + safe area + link preview + margin)
      const toolbarHeight = 96.0;

      // Calculate where the visible bottom edge is (above keyboard and toolbar)
      final visibleBottom = screenHeight - keyboardHeight - toolbarHeight;

      // Only scroll if caret is below visible area
      if (caretGlobal.dy > visibleBottom) {
        final scrollAmount = caretGlobal.dy - visibleBottom;
        final targetScroll = scrollPosition.pixels + scrollAmount;
        _quillScrollController.animateTo(
          targetScroll.clamp(0.0, scrollPosition.maxScrollExtent),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        );
      }
    } catch (e) {
      // Silently handle if render editor not ready
    }
  }

  /// Scrolls to caret with keyboard-aware timing
  void _scrollToCaretAfterKeyboard() {
    if (!mounted || !_focusNode.hasFocus) return;

    // Cancel any pending scroll timers to prevent conflicts
    for (final timer in _scrollTimers) {
      timer.cancel();
    }
    _scrollTimers.clear();

    // First scroll immediately after layout settles
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNode.hasFocus) return;
      _scrollToCaret();
    });

    // Second scroll during keyboard animation (~250ms)
    _scrollTimers.add(
      Timer(const Duration(milliseconds: 250), () {
        if (!mounted || !_focusNode.hasFocus) return;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_focusNode.hasFocus) return;
          _scrollToCaret();
        });
      }),
    );

    // Third scroll after keyboard animation fully completes (~500ms)
    // Some devices have slower keyboard animations
    _scrollTimers.add(
      Timer(const Duration(milliseconds: 500), () {
        if (!mounted || !_focusNode.hasFocus) return;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_focusNode.hasFocus) return;
          _scrollToCaret();
        });
      }),
    );
  }

  void _onNoteChanged(NoteEvent event) {
    if (!mounted || event.note.id != _note.id) return;
    if (!identical(event.note, _note)) {
      // Background notification actions update SQLite in a separate Flutter
      // engine. Merge only reminder-owned metadata so an editor that is open
      // in the main isolate keeps any unsaved title or content changes.
      _note.completed = event.note.completed;
      _note.reminder = event.note.reminder;
      _note.updatedAt = event.note.updatedAt;
    }
    setState(() {});
  }

  Future<void> _showOverdueReminderDialogIfNeeded() async {
    if (!mounted || !_note.hasReminderExpired) return;
    await DueReminderPresenter.instance.showIfDue(
      note: _note,
      shownOccurrences: _shownDueReminderOccurrences,
      context: context,
      onMarkDone: () async {
        if (!await _enqueueSave()) return false;
        final rowId = await _note.done();
        if (mounted) setState(() {});
        return rowId >= 0;
      },
    );
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

    // Insert: newline + audio tag + newline + transcript text + newline (for spacing)
    // Both tag and transcript will be inside the blockquote
    final insertText = '\n$audioTag\n$text\n';
    document.insert(length - 1, insertText);

    // Calculate positions for formatting
    final audioTagStart = length; // After the first newline
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
    _checklistEligibilityTimer?.cancel();
    _checklistLayoutRetryTimer?.cancel();
    _changesSubscription?.cancel();
    // Cancel pending scroll timers
    for (final timer in _scrollTimers) {
      timer.cancel();
    }
    _scrollTimers.clear();
    // Clear checkbox tracking state
    _bubbleUpdatedOffsets.clear();
    _checkboxService.invalidateCache();
    _controller.removeListener(_didChangeSelection);
    _controller.dispose();
    _titleController.dispose();
    _focusNode.removeListener(_focusListener);
    _titleFocusNode.removeListener(_titleFocusListener);
    _checklistPromptController.removeListener(_onChecklistPromptChanged);
    _checklistPromptController.dispose();
    _checklistProgress.dispose();
    _quillScrollController.removeListener(_requestChecklistPopupLayout);
    _focusNode.dispose();
    _titleFocusNode.dispose();
    _note.unsub("changed", _onNoteChanged);
    _quillScrollController.dispose();
    _carouselScrollController.dispose();
    _toolbarScrollController.dispose();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _changeTimer?.cancel();
      unawaited(_enqueueSave());
    } else if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showOverdueReminderDialogIfNeeded());
      });
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _requestChecklistPopupLayout();
    // Check keyboard visibility based on view insets
    // Guard against empty views on Windows during minimize/display changes
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final bottomInset = views.first.viewInsets.bottom;
    final keyboardVisible = bottomInset > 0;
    if (_isKeyboardVisible != keyboardVisible) {
      final wasHidden = !_isKeyboardVisible;
      setState(() {
        _isKeyboardVisible = keyboardVisible;
      });

      // Keyboard just appeared while editor has focus - scroll to caret
      if (keyboardVisible && wasHidden && _focusNode.hasFocus) {
        _scrollToCaretAfterKeyboard();
      }
    }
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
    final editor = PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_closeEditor(result));
      },
      child: AbsorbPointer(
        absorbing: _isClosing,
        child: Stack(
          key: _editorStackKey,
          fit: StackFit.expand,
          children: [
            Scaffold(
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
              appBar: NoteEditorAppBar(
                backgroundColor: backgroundColor,
                foregroundColor: foregroundColor,
                leadingWidth: isBigScreen(context) ? 96 : null,
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BackButton(
                      color: foregroundColor,
                      onPressed: () => unawaited(_closeEditor()),
                    ),
                    if (isBigScreen(context))
                      IconButton(
                        color: foregroundColor,
                        onPressed: () {
                          setState(() {
                            AppState.editorFullScreen =
                                !AppState.editorFullScreen;
                          });
                        },
                        icon: Icon(
                          AppState.editorFullScreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                        ),
                      ),
                  ],
                ),
                title: ValueListenableBuilder<({int checked, int total})>(
                  valueListenable: _checklistProgress,
                  builder: (context, progress, _) => NoteCheckboxProgressTitle(
                    checked: progress.checked,
                    total: progress.total,
                    foregroundColor: foregroundColor,
                    onTap: progress.total == 0
                        ? null
                        : () => unawaited(_openChecklistCollectionEditor()),
                  ),
                ),
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
                        NoteEditorAppBarActions(
                          note: _note,
                          foregroundColor: foregroundColor,
                          onColor: () => unawaited(_pickNoteColor()),
                          onReminder: () => unawaited(_editReminder()),
                          onPin: _togglePinned,
                          onLabels: () => unawaited(_editLabels()),
                          overflowMenu: _buildNoteOverflowMenu(),
                        ),
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
                            padding: const EdgeInsets.only(left: 16, right: 16),
                            child: Focus(
                              onKeyEvent: (node, event) {
                                if (event is KeyDownEvent) {
                                  if (event.logicalKey ==
                                          LogicalKeyboardKey.enter ||
                                      event.logicalKey ==
                                          LogicalKeyboardKey.tab) {
                                    _handleTitleEnterPressed();
                                    return KeyEventResult.handled;
                                  }
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
                                onSubmitted: (_) => _handleTitleEnterPressed(),
                                onEditingComplete: _handleTitleEnterPressed,
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w600,
                                  color: foregroundColor,
                                ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.only(bottom: 8),
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
                                side: BorderSide(
                                  width: 2,
                                  color: foregroundColor,
                                ),
                                splashRadius: 24,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.padded,
                              ),
                            ),
                            child: DefaultTextStyle(
                              style: TextStyle(color: foregroundColor),
                              child: Focus(
                                onKeyEvent: _handleKeyPressed,
                                child: Listener(
                                  behavior: HitTestBehavior.translucent,
                                  onPointerDown: (_) =>
                                      _handleChecklistEditorTap(),
                                  child: QuillEditor.basic(
                                    scrollController: _quillScrollController,
                                    focusNode: _focusNode,
                                    controller: _controller,
                                    config: QuillEditorConfig(
                                      editorKey: _editorKey,
                                      checkBoxReadOnly: _note.trashed,
                                      scrollable: false,
                                      padding: EdgeInsets.only(
                                        top: 0,
                                        bottom: 32,
                                        left: 16,
                                        right: 16,
                                      ),
                                      readOnlyMouseCursor:
                                          SystemMouseCursors.alias,
                                      showCursor:
                                          !_note.readOnly && !_note.trashed,
                                      enableInteractiveSelection: true,
                                      enableSelectionToolbar: true,
                                      placeholder: context.l10n.startWriting,
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
                                              imageEmbedConfig:
                                                  QuillEditorImageEmbedConfig(
                                                    imageProviderBuilder:
                                                        buildQuillImageProvider,
                                                    imageErrorWidgetBuilder:
                                                        buildQuillImageErrorWidget,
                                                  ),
                                            ),
                                      customLinkPrefixes: const ['audio://'],
                                      linkActionPickerDelegate:
                                          _audioLinkActionPicker,
                                      onLaunchUrl: (url) {
                                        return;
                                      },
                                    ),
                                  ),
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
                              noteLocked: _note.locked,
                              noteSessionUnlocked: _note.unlocked,
                              passwordProtectedDecoder:
                                  _note.decryptAttachmentForSession,
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
            if (_checklistPromptController.state.isVisible &&
                _checklistPopupGeometry != null)
              Positioned.fill(
                child: GestureDetector(
                  key: const ValueKey('focused_checklist_popup_barrier'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _dismissChecklistPopup,
                  child: const SizedBox.expand(),
                ),
              ),
            if (_checklistPromptController.state.isVisible &&
                _checklistPopupGeometry != null)
              _buildChecklistPopup(),
          ],
        ),
      ),
    );

    return editor;
  }

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
        index: _note.images.length,
        blurredThumbnail: preparedImage.blurredThumbnail,
      );

      if (!mounted) return;
      final added = await commitAttachmentWithRetry(
        context: context,
        sourcePath: preparedImage.path,
        commit: () => _note.addImage(noteImage),
        beforeFailurePrompt: () async => dismissProcessing(),
        beforeRetry: () async => showProcessing(),
        sourceLease: preparedImage.sourceLease,
      );
      if (added && mounted) _scrollToAttachments();
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

  void _handleAudioAttachment() async {
    if (_checkAttachmentLimit()) return;

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
        commit: () => _note.addRecording(recording),
      );
      if (!added || !mounted) return;
      _scrollToAttachments();
      // Append transcription to note if provided
      if (result.transcription != null && result.transcription!.isNotEmpty) {
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
      allowFullScreen: true,
    );
    _scrollToAttachments();
  }

  Widget _buildToolbar() {
    return NoteEditorToolbar(
      key: const Key('note_editor_toolbar'),
      controller: _controller,
      focusNode: _focusNode,
      readOnly: _note.readOnly,
      parentColor: _note.color,
      scrollController: _toolbarScrollController,
      note: _note,
      imageAttachmentPreparationService:
          widget.imageAttachmentPreparationService,
      onAppendTranscript: _appendTranscriptToNote,
      onAttachmentAdded: _scrollToAttachments,
      showKeyboardHide: _isKeyboardVisible,
      onHideKeyboard: _focusNode.unfocus,
    );
  }

  void _scheduleAutosave() {
    if (_isClosing) return;
    _changeTimer?.cancel();
    _changeTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_enqueueSave());
    });
  }

  _NoteEditorSaveSnapshot _captureSaveSnapshot() {
    final title = _titleController.text;
    final contentDelta = _controller.document.toDelta().toJson();
    final combinedDeltaJson = <Map<String, dynamic>>[];

    if (title.isNotEmpty) {
      combinedDeltaJson.add({'insert': title});
      combinedDeltaJson.add({
        'insert': '\n',
        'attributes': {'header': 1},
      });
    }

    combinedDeltaJson.addAll(List<Map<String, dynamic>>.from(contentDelta));
    final combinedDoc = documentFromJsonSafe(combinedDeltaJson);

    return _NoteEditorSaveSnapshot(
      title: title,
      content: json.encode(combinedDeltaJson),
      plainText: combinedDoc.toPlainText().trim(),
      bodyPlainText: _controller.document.toPlainText().trim(),
    );
  }

  Future<bool> _enqueueSave() {
    late final _NoteEditorSaveSnapshot snapshot;
    try {
      snapshot = _captureSaveSnapshot();
    } catch (error, stackTrace) {
      AppLogger.error('Failed to capture note editor state', error, stackTrace);
      return Future<bool>.value(false);
    }

    final completer = Completer<bool>();
    _saveTail = _saveTail.then((_) async {
      try {
        completer.complete(await _persistSnapshot(snapshot));
      } catch (error, stackTrace) {
        AppLogger.error('Error saving note', error, stackTrace);
        completer.complete(false);
      }
    });
    return completer.future;
  }

  Future<void> _enqueueLock(String password) {
    final pending = _pendingLockOperation;
    if (pending != null) return pending;

    _changeTimer?.cancel();
    late final _NoteEditorSaveSnapshot snapshot;
    try {
      snapshot = _captureSaveSnapshot();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to capture note state before locking',
        error,
        stackTrace,
      );
      return Future<void>.error(error, stackTrace);
    }

    if (mounted) {
      setState(() => _isLockQueued = true);
    } else {
      _isLockQueued = true;
    }

    final operation = _saveTail.then((_) async {
      if (!await _persistSnapshot(snapshot)) {
        throw const NoteLockException(
          'The latest editor changes could not be saved before locking',
        );
      }
      await _note.lock(password);
    });
    _pendingLockOperation = operation;
    _saveTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    unawaited(
      operation.then<void>(
        (_) => _finishQueuedLock(operation),
        onError: (Object _, StackTrace _) => _finishQueuedLock(operation),
      ),
    );
    return operation;
  }

  void _finishQueuedLock(Future<void> operation) {
    if (!identical(_pendingLockOperation, operation)) return;
    _pendingLockOperation = null;
    if (mounted) {
      setState(() => _isLockQueued = false);
    } else {
      _isLockQueued = false;
    }
  }

  Future<void> _enqueueLockRemoval(String password) {
    final pending = _pendingLockRemovalOperation;
    if (pending != null) return pending;

    _changeTimer?.cancel();
    late final _NoteEditorSaveSnapshot snapshot;
    try {
      snapshot = _captureSaveSnapshot();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to capture note state before removing its lock',
        error,
        stackTrace,
      );
      return Future<void>.error(error, stackTrace);
    }

    if (mounted) {
      setState(() => _isLockRemovalQueued = true);
    } else {
      _isLockRemovalQueued = true;
    }

    final operation = _saveTail.then((_) async {
      if (!await _persistSnapshot(snapshot)) {
        throw const NoteLockRemovalException(
          'The latest editor changes could not be saved before removing the lock',
        );
      }
      await _note.removeLock(password);
    });
    _pendingLockRemovalOperation = operation;
    _saveTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    unawaited(
      operation.then<void>(
        (_) => _finishQueuedLockRemoval(operation),
        onError: (Object _, StackTrace _) =>
            _finishQueuedLockRemoval(operation),
      ),
    );
    return operation;
  }

  void _finishQueuedLockRemoval(Future<void> operation) {
    if (!identical(_pendingLockRemovalOperation, operation)) return;
    _pendingLockRemovalOperation = null;
    if (mounted) {
      setState(() => _isLockRemovalQueued = false);
    } else {
      _isLockRemovalQueued = false;
    }
  }

  Future<bool> _persistSnapshot(_NoteEditorSaveSnapshot snapshot) async {
    if (widget.deleteIfUnchanged && _initialPlainText != null) {
      if (snapshot.plainText == _initialPlainText) {
        if (_note.id == null) return true;
        try {
          return await _note.delete() >= 0;
        } catch (error, stackTrace) {
          AppLogger.error('Error deleting unchanged note', error, stackTrace);
          return false;
        }
      }
    }

    if (_note.isEmpty && snapshot.isEmpty) {
      if (_note.id == null) return true;
      try {
        return await _note.delete() >= 0;
      } catch (error, stackTrace) {
        AppLogger.error('Error deleting empty note', error, stackTrace);
        return false;
      }
    }

    if (_note.content == snapshot.content &&
        (_note.title ?? '') == snapshot.title) {
      return true;
    }

    try {
      return await _note.saveEditorSnapshot(
            title: snapshot.title,
            content: snapshot.content,
            plainText: snapshot.plainText,
          ) >=
          0;
    } catch (error, stackTrace) {
      AppLogger.error('Error saving note', error, stackTrace);
      if (mounted) {
        snackbar(context.l10n.errorSavingNote, Colors.red);
      }
      return false;
    }
  }

  Future<void> _closeEditor([Object? result]) async {
    if (_isClosing || _allowPop) return;

    _changeTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    if (mounted) {
      setState(() => _isClosing = true);
    }

    final saved = await _enqueueSave();
    if (!saved) {
      _cancelCloseAfterFailure();
      return;
    }

    if (AppState.forgetLockedNotePassword && _note.locked) {
      try {
        await _note.clearPassword();
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to restore protected note state before closing',
          error,
          stackTrace,
        );
        _cancelCloseAfterFailure();
        return;
      }
    }

    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      Navigator.of(context).pop(result);
    }
  }

  void _cancelCloseAfterFailure() {
    if (!mounted) return;
    setState(() {
      _isClosing = false;
      _allowPop = false;
    });
    snackbar(context.l10n.errorSavingNote, Colors.red);
  }

  Future<void> _pickNoteColor() async {
    final restoreEditorFocus = _focusNode.hasFocus;
    _focusNode.unfocus();
    final color = await colorPicker(
      context,
      context.l10n.pickNoteColor,
      _note.color,
    );
    if (restoreEditorFocus && mounted) _focusNode.requestFocus();
    if (color == null || !mounted) return;
    _note.color = color;
    await _note.save();
    if (!mounted) return;
    setState(() => _backgroundColor = color);
  }

  Future<void> _editReminder() async {
    final selected = await reminder(context, initialReminder: _note.reminder);
    if (selected == null) return;
    final result = await _note.setReminder(selected);
    if (!mounted) return;
    if (result.persisted) {
      _shownDueReminderOccurrences.clear();
      setState(() {});
    }
    ReminderScheduleResultPresenter.instance.show(context, result);
    if (result.delivery?.state == ReminderDeliveryState.scheduled) {
      unawaited(
        ReviewPromptService.instance.recordPositiveMilestone(
          ReviewMilestone.reminderScheduled,
        ),
      );
    }
  }

  void _togglePinned() {
    _note.pinned = !_note.pinned;
    unawaited(_note.save());
    setState(() {});
  }

  Future<void> _editLabels() async {
    final selectedLabels = await labels(
      context,
      mode: Labels.labelsModeSelect,
      initiallySelected: _note.labels?.split(',') ?? const [],
    );
    if (selectedLabels == null || !mounted) return;
    _note.labels = selectedLabels.join(',');
    await _note.save();
    if (mounted) setState(() {});
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
    _checklistPromptController.updateBlock(_checklistBlockAtCaret);
    _checklistPromptController.updateInteraction(
      hasFocus: _focusNode.hasFocus,
      hasCollapsedSelection: _hasCollapsedChecklistSelection,
    );

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
    _scheduleChecklistPopupLayout();
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
    _scheduleAutosave();
    _updateChecklistProgress();
    _scheduleChecklistEligibilityRefresh();

    // Skip checkbox processing if we're applying checkbox cascade/bubble changes
    if (_isApplyingCheckboxChanges) return;

    // Handle nested checkbox cascade/bubble logic
    // Fire-and-forget with error handling
    _handleCheckboxChange(event).catchError((error) {
      // Log error but don't crash - checkbox cascade is non-critical
      debugPrint('Checkbox cascade error: $error');
    });
  }

  void _updateChecklistProgress() {
    final next = _checklistDeltaCodec.checklistProgress(_controller.document);
    if (_checklistProgress.value == next) return;
    _checklistProgress.value = next;
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

    if (!context.mounted) return;

    switch (result) {
      case PasteCancelled():
        // User cancelled, do nothing
        break;

      case PastePlainText(:final text):
        try {
          insertPlainTextIntoController(_controller, text);
          snackbar(context.l10n.pastedAsPlainText, Colors.green);
        } catch (error, stackTrace) {
          AppLogger.error('Failed to paste plain text', error, stackTrace);
          snackbar(context.l10n.somethingWentWrongTryAgain, Colors.red);
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

        if (!context.mounted) return;

        if (document != null) {
          try {
            insertDocumentIntoController(_controller, document);
            snackbar(context.l10n.contentInserted, Colors.green);
          } catch (error, stackTrace) {
            AppLogger.error(
              'Failed to insert pasted content',
              error,
              stackTrace,
            );
            snackbar(context.l10n.somethingWentWrongTryAgain, Colors.red);
          }
        }
        break;
    }
  }

  Widget _buildNoteOverflowMenu() {
    return NoteEditorOverflowMenu(
      note: _note,
      lockBusy: _isLockQueued || _isLockRemovalQueued,
      onArchivedChanged: (value) => unawaited(_setArchived(value)),
      onReadOnlyChanged: (value) => unawaited(_setReadOnly(value)),
      onLockedChanged: (value) => unawaited(_setLocked(value)),
      onSaveAs: () => showExportOptions(context, _note, _controller),
      onCopyAs: () => showCopyOptions(context, _note, _controller),
      onPasteAs: () => unawaited(_handlePasteAs(context)),
      onShare: () => unawaited(_shareCurrentNote()),
      onDuplicate: () => unawaited(_duplicateCurrentNote()),
      onDelete: () => unawaited(_moveCurrentNoteToTrash()),
    );
  }

  Future<void> _setArchived(bool value) async {
    if (!await _enqueueSave()) return;
    _note.archived = value;
    await _note.save();
    if (mounted) setState(() {});
  }

  Future<void> _setReadOnly(bool value) async {
    if (!await _enqueueSave()) return;
    _note.readOnly = value;
    _controller.readOnly = value;
    await _note.save();
    if (mounted) setState(() {});
  }

  Future<void> _setLocked(bool value) async {
    if (value) {
      final lockedNotes = await Note.get(NoteType.locked);
      if (!mounted) return;
      final check = EntitlementGuard.canLockNote(
        lockedNotes.length,
        context.l10n,
      );
      if (!check.allowed) {
        showPaywall(
          context,
          feature: GatedFeature.lockNote,
          customMessage: check.denialReason,
        );
        return;
      }
      final password = await showLockNoteDialog(context);
      if (password == null || password.isEmpty || !mounted) return;
      try {
        await _enqueueLock(password);
        if (mounted) snackbar(context.l10n.noteLocked, Colors.green);
      } catch (error, stackTrace) {
        AppLogger.error('Failed to lock note', error, stackTrace);
        if (mounted) {
          snackbar(context.l10n.somethingWentWrongTryAgain, Colors.red);
        }
      }
    } else {
      final password = _note.password ?? await showLockNoteDialog(context);
      if (password == null || password.isEmpty) return;
      try {
        await _enqueueLockRemoval(password);
        if (mounted) snackbar(context.l10n.lockRemoved, Colors.green);
      } catch (error, stackTrace) {
        AppLogger.error('Failed to remove note lock', error, stackTrace);
        if (mounted) {
          snackbar(context.l10n.somethingWentWrongTryAgain, Colors.red);
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _shareCurrentNote() async {
    if (!await _enqueueSave() || !mounted) return;
    await showShareNoteDialog(context, _note);
  }

  Future<void> _duplicateCurrentNote() async {
    if (_note.id == null || !await _enqueueSave()) return;
    try {
      await NoteEditorActionService.duplicate(_note);
    } catch (error, stackTrace) {
      AppLogger.error('Duplicated note could not be locked', error, stackTrace);
      if (mounted) {
        snackbar(context.l10n.somethingWentWrongTryAgain, Colors.orange);
      }
      return;
    }
    if (mounted) snackbar(context.l10n.noteDuplicated, Colors.green);
  }

  Future<void> _moveCurrentNoteToTrash() async {
    if (_note.id == null || !await _enqueueSave()) return;
    await _note.moveToTrash();
    if (mounted) await _closeEditor();
  }
}

class _NoteEditorSaveSnapshot {
  final String title;
  final String content;
  final String plainText;
  final String bodyPlainText;

  const _NoteEditorSaveSnapshot({
    required this.title,
    required this.content,
    required this.plainText,
    required this.bodyPlainText,
  });

  bool get isEmpty => title.isEmpty && bodyPlainText.isEmpty;
}
