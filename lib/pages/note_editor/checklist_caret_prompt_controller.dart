import 'package:better_keep/services/checklist_delta_codec.dart';
import 'package:flutter/foundation.dart';

enum ChecklistCaretPromptPhase {
  hidden,
  ineligible,
  waitingForLayout,
  visible,
  dismissedUntilNextEligibleTap,
}

@immutable
class ChecklistCaretPromptState {
  const ChecklistCaretPromptState({
    required this.phase,
    this.block,
    this.layoutAttempts = 0,
    this.layoutPending = false,
  });

  const ChecklistCaretPromptState.hidden()
    : phase = ChecklistCaretPromptPhase.hidden,
      block = null,
      layoutAttempts = 0,
      layoutPending = false;

  final ChecklistCaretPromptPhase phase;
  final ChecklistBlockLookupResult? block;
  final int layoutAttempts;
  final bool layoutPending;

  bool get isVisible => phase == ChecklistCaretPromptPhase.visible;
  bool get needsLayout => layoutPending;
}

/// Owns the checklist prompt lifecycle independently of caret geometry.
/// Timeout and Escape dismissal can only be cleared by a new eligible tap.
class ChecklistCaretPromptController extends ChangeNotifier {
  ChecklistCaretPromptController({this.maxLayoutAttempts = 8});

  final int maxLayoutAttempts;

  ChecklistCaretPromptState _state = const ChecklistCaretPromptState.hidden();
  ChecklistBlockLookupResult? _block;
  bool _hasFocus = false;
  bool _hasCollapsedSelection = false;
  bool _dismissedUntilNextEligibleTap = false;

  ChecklistCaretPromptState get state => _state;

  void updateBlock(ChecklistBlockLookupResult? block) {
    _block = block;
    _evaluate(resetLayoutAttempts: true);
  }

  void updateInteraction({
    required bool hasFocus,
    required bool hasCollapsedSelection,
  }) {
    if (_hasFocus == hasFocus &&
        _hasCollapsedSelection == hasCollapsedSelection) {
      return;
    }
    _hasFocus = hasFocus;
    _hasCollapsedSelection = hasCollapsedSelection;
    _evaluate(resetLayoutAttempts: true);
  }

  void onEditorTap({
    required ChecklistBlockLookupResult? block,
    required bool hasFocus,
    required bool hasCollapsedSelection,
  }) {
    _block = block;
    _hasFocus = hasFocus;
    _hasCollapsedSelection = hasCollapsedSelection;
    if (block?.isEligible ?? false) {
      _dismissedUntilNextEligibleTap = false;
    }
    _evaluate(resetLayoutAttempts: true);
  }

  void dismissUntilNextEligibleTap() {
    _dismissedUntilNextEligibleTap = true;
    _emit(
      ChecklistCaretPromptState(
        phase: ChecklistCaretPromptPhase.dismissedUntilNextEligibleTap,
        block: _block,
      ),
    );
  }

  void requestLayout() {
    if (!_canPresent) return;
    _emit(
      ChecklistCaretPromptState(
        phase: _state.isVisible
            ? ChecklistCaretPromptPhase.visible
            : ChecklistCaretPromptPhase.waitingForLayout,
        block: _block,
        layoutPending: true,
      ),
    );
  }

  /// Records an unavailable caret rectangle and returns whether another retry
  /// should be scheduled.
  bool markLayoutUnavailable() {
    if (!_state.needsLayout) return false;
    final attempts = _state.layoutAttempts + 1;
    _emit(
      ChecklistCaretPromptState(
        phase: _state.phase,
        block: _block,
        layoutAttempts: attempts,
        layoutPending: true,
      ),
    );
    return attempts < maxLayoutAttempts;
  }

  void markLayoutReady() {
    if (!_state.needsLayout || !_canPresent) return;
    _emit(
      ChecklistCaretPromptState(
        phase: ChecklistCaretPromptPhase.visible,
        block: _block,
        layoutAttempts: _state.layoutAttempts,
      ),
    );
  }

  bool get _canPresent =>
      !_dismissedUntilNextEligibleTap &&
      _hasFocus &&
      _hasCollapsedSelection &&
      (_block?.isEligible ?? false);

  void _evaluate({required bool resetLayoutAttempts}) {
    final interactive = _hasFocus && _hasCollapsedSelection;
    final phase = _dismissedUntilNextEligibleTap
        ? ChecklistCaretPromptPhase.dismissedUntilNextEligibleTap
        : !interactive || !(_block?.isChecklistLine ?? false)
        ? ChecklistCaretPromptPhase.hidden
        : (_block?.isEligible ?? false)
        ? _state.isVisible
              ? ChecklistCaretPromptPhase.visible
              : ChecklistCaretPromptPhase.waitingForLayout
        : ChecklistCaretPromptPhase.ineligible;
    _emit(
      ChecklistCaretPromptState(
        phase: phase,
        block: _block,
        layoutAttempts: resetLayoutAttempts ? 0 : _state.layoutAttempts,
        layoutPending:
            phase == ChecklistCaretPromptPhase.waitingForLayout ||
            phase == ChecklistCaretPromptPhase.visible,
      ),
    );
  }

  void _emit(ChecklistCaretPromptState next) {
    final previous = _state;
    if (previous.phase == next.phase &&
        identical(previous.block, next.block) &&
        previous.layoutAttempts == next.layoutAttempts &&
        previous.layoutPending == next.layoutPending) {
      return;
    }
    _state = next;
    if (kDebugMode) {
      debugPrint(
        '[ChecklistPrompt] ${previous.phase.name} -> ${next.phase.name}; '
        'reason=${next.block?.failureReason?.name ?? 'none'}; '
        'layoutAttempts=${next.layoutAttempts}; '
        'layoutPending=${next.layoutPending}',
      );
    }
    notifyListeners();
  }
}
