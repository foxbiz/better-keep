import 'package:better_keep/pages/note_editor/note_find_controller.dart';
import 'package:better_keep/services/note_search_service.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' as intl;

enum _FindOption { caseSensitive, wholeWord, smart, regularExpression }

class NoteFindBar extends StatelessWidget {
  const NoteFindBar({
    super.key,
    required this.controller,
    required this.canEdit,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onClose,
    required this.onReplace,
    required this.onReplaceAll,
  });

  final NoteFindController controller;
  final bool canEdit;
  final Color backgroundColor;
  final Color foregroundColor;
  final ValueChanged<bool> onClose;
  final VoidCallback onReplace;
  final VoidCallback onReplaceAll;

  static const double _leadingControlExtent = 40;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.isOpen) return const SizedBox.shrink();
        final surfaceColor = Color.alphaBlend(
          foregroundColor.withValues(alpha: 0.08),
          backgroundColor,
        );
        return Align(
          alignment: AlignmentDirectional.topEnd,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Material(
              key: const ValueKey('note_find_bar'),
              color: surfaceColor,
              elevation: 3,
              child: SafeArea(
                top: false,
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildFindRow(context),
                      if (controller.replaceExpanded &&
                          canEdit &&
                          controller.mode != NoteSearchMode.smart)
                        _buildReplaceRow(context),
                      if (controller.error != null)
                        _buildError(context, controller.error!),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFindRow(BuildContext context) {
    final showLeading = canEdit && controller.mode != NoteSearchMode.smart;
    final leading = showLeading
        ? _buildLeadingSlot(
            IconButton(
              key: const ValueKey('note_find_toggle_replace'),
              visualDensity: VisualDensity.compact,
              tooltip: controller.replaceExpanded
                  ? context.l10n.hideReplace
                  : context.l10n.showReplace,
              onPressed: controller.toggleReplace,
              icon: Icon(
                controller.replaceExpanded
                    ? Icons.expand_more
                    : Icons.chevron_right,
              ),
            ),
          )
        : null;
    final findInput = Expanded(
      child: Focus(
        onKeyEvent: _handleFindKey,
        child: TextField(
          key: const ValueKey('note_find_query'),
          controller: controller.queryController,
          focusNode: controller.queryFocusNode,
          maxLines: 1,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => controller.next(),
          decoration: InputDecoration(
            isDense: true,
            hintText: context.l10n.findInNote,
            border: const OutlineInputBorder(),
            suffixIcon: _buildResultCount(context),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 64,
              maxWidth: 64,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 10,
            ),
          ),
        ),
      ),
    );
    final options = _buildOptions(context);
    final previous = _buildPreviousButton(context);
    final next = _buildNextButton(context);
    final close = _buildCloseButton(context);

    return Row(children: [?leading, findInput, options, previous, next, close]);
  }

  Widget _buildPreviousButton(BuildContext context) {
    return IconButton(
      key: const ValueKey('note_find_previous'),
      visualDensity: VisualDensity.compact,
      tooltip: context.l10n.previousMatch,
      onPressed: controller.canNavigate ? controller.previous : null,
      icon: const Icon(Icons.keyboard_arrow_up),
    );
  }

  Widget _buildNextButton(BuildContext context) {
    return IconButton(
      key: const ValueKey('note_find_next'),
      visualDensity: VisualDensity.compact,
      tooltip: context.l10n.nextMatch,
      onPressed: controller.canNavigate ? controller.next : null,
      icon: const Icon(Icons.keyboard_arrow_down),
    );
  }

  Widget _buildCloseButton(BuildContext context) {
    return IconButton(
      key: const ValueKey('note_find_close'),
      visualDensity: VisualDensity.compact,
      tooltip: context.l10n.close,
      onPressed: () => onClose(false),
      icon: const Icon(Icons.close),
    );
  }

  Widget _buildReplaceRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth - _leadingControlExtent < 440;
          return Row(
            children: [
              _buildLeadingSlot(),
              Expanded(
                child: Focus(
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.enter) {
                      onReplace();
                      return KeyEventResult.handled;
                    }
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.escape) {
                      onClose(true);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    key: const ValueKey('note_find_replacement'),
                    controller: controller.replacementController,
                    focusNode: controller.replacementFocusNode,
                    maxLines: 1,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => onReplace(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: context.l10n.replace,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('note_find_replace'),
                tooltip: context.l10n.replace,
                onPressed: controller.canReplace ? onReplace : null,
                icon: const Icon(Icons.find_replace),
              ),
              if (compact)
                IconButton(
                  key: const ValueKey('note_find_replace_all'),
                  tooltip: context.l10n.replaceAll,
                  onPressed: controller.canReplace ? onReplaceAll : null,
                  icon: const Icon(Icons.done_all),
                )
              else
                TextButton.icon(
                  key: const ValueKey('note_find_replace_all'),
                  onPressed: controller.canReplace ? onReplaceAll : null,
                  icon: const Icon(Icons.done_all),
                  label: Text(context.l10n.replaceAll),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLeadingSlot([Widget? child]) {
    return SizedBox(width: _leadingControlExtent, child: child);
  }

  Widget _buildResultCount(BuildContext context) {
    if (controller.isSearching) {
      return Semantics(
        label: context.l10n.searching,
        child: const Center(
          child: SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final queryEmpty = controller.queryController.text.isEmpty;
    if (queryEmpty) return const SizedBox.shrink();

    final noMatches = controller.matchCount == 0;
    final current = noMatches ? 0 : controller.activeIndex + 1;
    final total = controller.matchCount;
    final visualLabel = noMatches
        ? '0/0'
        : _compactResultCount(context, current: current, total: total);
    final exactLabel = noMatches
        ? context.l10n.noMatches
        : context.l10n.searchResultCount(current, total);
    final count = Semantics(
      liveRegion: true,
      label: exactLabel,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              visualLabel,
              key: const ValueKey('note_find_result_count'),
              maxLines: 1,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ),
      ),
    );
    return Tooltip(
      message: exactLabel,
      excludeFromSemantics: true,
      child: count,
    );
  }

  String _compactResultCount(
    BuildContext context, {
    required int current,
    required int total,
  }) {
    if (current < 1000 && total < 1000) return '$current/$total';
    final formatter = intl.NumberFormat.compact(
      locale: Localizations.localeOf(context).toLanguageTag(),
    )..maximumFractionDigits = 1;
    return '${formatter.format(current)}/${formatter.format(total)}';
  }

  Widget _buildOptions(BuildContext context) {
    final selected =
        controller.caseSensitive ||
        controller.wholeWord ||
        controller.mode != NoteSearchMode.literal;
    return PopupMenuButton<_FindOption>(
      key: const ValueKey('note_find_options'),
      tooltip: context.l10n.searchOptions,
      icon: Icon(
        Icons.tune,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      onSelected: (option) {
        switch (option) {
          case _FindOption.caseSensitive:
            controller.setCaseSensitive(!controller.caseSensitive);
          case _FindOption.wholeWord:
            controller.setWholeWord(!controller.wholeWord);
          case _FindOption.smart:
            controller.setMode(
              controller.mode == NoteSearchMode.smart
                  ? NoteSearchMode.literal
                  : NoteSearchMode.smart,
            );
          case _FindOption.regularExpression:
            controller.setMode(
              controller.mode == NoteSearchMode.regularExpression
                  ? NoteSearchMode.literal
                  : NoteSearchMode.regularExpression,
            );
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          key: const ValueKey('note_find_option_case'),
          value: _FindOption.caseSensitive,
          checked: controller.caseSensitive,
          enabled: controller.mode != NoteSearchMode.smart,
          child: Text(context.l10n.matchCase),
        ),
        CheckedPopupMenuItem(
          key: const ValueKey('note_find_option_whole_word'),
          value: _FindOption.wholeWord,
          checked: controller.wholeWord,
          enabled: controller.mode != NoteSearchMode.smart,
          child: Text(context.l10n.matchWholeWord),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          key: const ValueKey('note_find_option_smart'),
          value: _FindOption.smart,
          checked: controller.mode == NoteSearchMode.smart,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(context.l10n.smartMatch),
            subtitle: Text(context.l10n.smartMatchDescription),
          ),
        ),
        CheckedPopupMenuItem(
          key: const ValueKey('note_find_option_regex'),
          value: _FindOption.regularExpression,
          checked: controller.mode == NoteSearchMode.regularExpression,
          child: Text(context.l10n.regularExpressionAdvanced),
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context, NoteSearchError error) {
    final message = switch (error) {
      NoteSearchError.invalidRegularExpression =>
        context.l10n.invalidRegularExpression,
      NoteSearchError.zeroLengthMatchesUnsupported =>
        context.l10n.zeroLengthRegexUnsupported,
      NoteSearchError.invalidReplacementReference =>
        context.l10n.invalidReplacementReference,
    };
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          canEdit && controller.mode != NoteSearchMode.smart ? 48 : 8,
          4,
          8,
          2,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleFindKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.f3) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        controller.previous();
      } else {
        controller.next();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      onClose(true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
