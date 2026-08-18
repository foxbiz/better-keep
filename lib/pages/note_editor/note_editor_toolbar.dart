import 'package:better_keep/components/adaptive_toolbar.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/pages/note_editor/toolbar/align_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/attach_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/checklist_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/indent_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/line_spacing_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/link_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/style_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/text_color_button.dart';
import 'package:better_keep/pages/note_editor/toolbar/text_size_button.dart';
import 'package:better_keep/pages/note_editor/table/note_table_button.dart';
import 'package:better_keep/pages/note_editor/table/note_table_controller.dart';
import 'package:better_keep/services/image_attachment_preparation_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

@immutable
class NoteEditorHistoryBinding {
  const NoteEditorHistoryBinding({
    required this.listenable,
    required this.canUndo,
    required this.canRedo,
    required this.undo,
    required this.redo,
  });

  factory NoteEditorHistoryBinding.quill(QuillController controller) {
    return NoteEditorHistoryBinding(
      listenable: controller,
      canUndo: () => controller.hasUndo,
      canRedo: () => controller.hasRedo,
      undo: controller.undo,
      redo: controller.redo,
    );
  }

  final Listenable listenable;
  final bool Function() canUndo;
  final bool Function() canRedo;
  final VoidCallback undo;
  final VoidCallback redo;
}

class NoteEditorHistoryButtons extends StatelessWidget {
  const NoteEditorHistoryButtons({
    super.key,
    required this.binding,
    required this.readOnly,
  });

  final NoteEditorHistoryBinding binding;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: binding.listenable,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('editor_toolbar_undo'),
            icon: const Icon(Icons.undo),
            tooltip: context.l10n.undo,
            onPressed: !readOnly && binding.canUndo() ? binding.undo : null,
          ),
          IconButton(
            key: const ValueKey('editor_toolbar_redo'),
            icon: const Icon(Icons.redo),
            tooltip: context.l10n.redo,
            onPressed: !readOnly && binding.canRedo() ? binding.redo : null,
          ),
        ],
      ),
    );
  }
}

/// The shared formatting toolbar used by the normal and focused note editors.
///
/// A focused checklist row deliberately omits document-structural controls,
/// while retaining the exact same toolbar shell, buttons, and sizing.
class NoteEditorToolbar extends StatelessWidget {
  const NoteEditorToolbar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.readOnly,
    required this.parentColor,
    this.scrollController,
    this.note,
    this.imageAttachmentPreparationService,
    this.onAppendTranscript,
    this.onAttachmentAdded,
    this.showKeyboardHide = false,
    this.onHideKeyboard,
    this.showHistory = true,
    this.historyBinding,
    this.showAttachments = true,
    this.showChecklist = true,
    this.showBlockLists = true,
    this.showIndent = true,
    this.tableController,
  });

  final QuillController controller;
  final FocusNode focusNode;
  final bool readOnly;
  final Color parentColor;
  final ScrollController? scrollController;
  final Note? note;
  final ImageAttachmentPreparationService? imageAttachmentPreparationService;
  final void Function(String text, NoteRecording recording)? onAppendTranscript;
  final VoidCallback? onAttachmentAdded;
  final bool showKeyboardHide;
  final VoidCallback? onHideKeyboard;
  final bool showHistory;
  final NoteEditorHistoryBinding? historyBinding;
  final bool showAttachments;
  final bool showChecklist;
  final bool showBlockLists;
  final bool showIndent;
  final NoteTableController? tableController;

  Widget _styleButton(Attribute attribute) => StyleButton(
    attribute: attribute,
    focusNode: focusNode,
    controller: controller,
    readOnly: readOnly,
  );

  @override
  Widget build(BuildContext context) {
    assert(!showAttachments || note != null);
    final foregroundColor = isDark(parentColor) ? Colors.white : Colors.black;
    final isIOS = Theme.of(context).platform == TargetPlatform.iOS;

    return AdaptiveToolbar(
      key: const ValueKey('note_editor_toolbar_surface'),
      parentColor: parentColor,
      scrollController: scrollController,
      children: [
        if (isIOS)
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: showKeyboardHide
                ? IconButton(
                    icon: const Icon(Icons.keyboard_hide),
                    onPressed: onHideKeyboard,
                    tooltip: context.l10n.hideKeyboard,
                  )
                : const SizedBox.shrink(),
          ),
        if (showHistory)
          NoteEditorHistoryButtons(
            binding:
                historyBinding ?? NoteEditorHistoryBinding.quill(controller),
            readOnly: readOnly,
          ),
        if (showAttachments)
          AttachButton(
            readOnly: readOnly,
            note: note!,
            imageAttachmentPreparationService:
                imageAttachmentPreparationService,
            onAppendTranscript: onAppendTranscript,
            onAttachmentAdded: onAttachmentAdded,
          ),
        TextColorButton(
          color: foregroundColor,
          focusNode: focusNode,
          readOnly: readOnly,
          controller: controller,
        ),
        if (showChecklist)
          CheckListButton(
            focusNode: focusNode,
            controller: controller,
            readOnly: readOnly,
          ),
        if (enableTableCreation && showBlockLists && tableController != null)
          NoteTableButton(
            controller: controller,
            readOnly: readOnly,
            tableController: tableController!,
          ),
        LinkButton(controller: controller, readOnly: readOnly),
        if (showBlockLists) ...[
          _styleButton(Attribute.ul),
          _styleButton(Attribute.ol),
        ],
        _styleButton(Attribute.strikeThrough),
        _styleButton(Attribute.bold),
        _styleButton(Attribute.italic),
        _styleButton(Attribute.underline),
        AlignButton(
          focusNode: focusNode,
          controller: controller,
          readOnly: readOnly,
        ),
        if (showIndent)
          IndentButton(
            focusNode: focusNode,
            controller: controller,
            readOnly: readOnly,
          ),
        TextSizeButton(
          focusNode: focusNode,
          controller: controller,
          readOnly: readOnly,
        ),
        LineSpacingButton(
          focusNode: focusNode,
          controller: controller,
          readOnly: readOnly,
        ),
      ],
    );
  }
}
