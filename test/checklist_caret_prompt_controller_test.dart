import 'package:better_keep/pages/note_editor/checklist_caret_prompt_controller.dart';
import 'package:better_keep/services/checklist_delta_codec.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final codec = ChecklistDeltaCodec(newId: () => 'item');
  final eligibleDocument = documentFromJsonSafe([
    {'insert': 'Task'},
    {
      'insert': '\n',
      'attributes': {'list': 'unchecked'},
    },
  ]);
  final eligible = codec.findChecklistBlockAt(eligibleDocument, 0);
  final ineligibleDocument = documentFromJsonSafe([
    {'insert': 'Task'},
    {
      'insert': '\n',
      'attributes': {'list': 'unchecked', 'header': 2},
    },
  ]);
  final ineligible = codec.findChecklistBlockAt(ineligibleDocument, 0);

  test('moves from eligibility through layout to visible', () {
    final controller = ChecklistCaretPromptController();
    addTearDown(controller.dispose);

    controller.updateBlock(eligible);
    expect(controller.state.phase, ChecklistCaretPromptPhase.hidden);

    controller.updateInteraction(hasFocus: true, hasCollapsedSelection: true);
    expect(controller.state.phase, ChecklistCaretPromptPhase.waitingForLayout);

    controller.markLayoutReady();
    expect(controller.state.phase, ChecklistCaretPromptPhase.visible);
  });

  test('eligible taps keep the prompt visible and request fresh layout', () {
    final controller = ChecklistCaretPromptController();
    addTearDown(controller.dispose);
    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    controller.markLayoutReady();

    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    expect(controller.state.phase, ChecklistCaretPromptPhase.visible);
    expect(controller.state.needsLayout, isTrue);
  });

  test('a tap outside checklist text hides the prompt', () {
    final controller = ChecklistCaretPromptController();
    addTearDown(controller.dispose);
    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    controller.markLayoutReady();

    controller.onEditorTap(
      block: null,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    expect(controller.state.phase, ChecklistCaretPromptPhase.hidden);
  });

  test('losing editor focus hides a visible prompt', () {
    final controller = ChecklistCaretPromptController();
    addTearDown(controller.dispose);
    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    controller.markLayoutReady();

    controller.updateInteraction(hasFocus: false, hasCollapsedSelection: true);
    expect(controller.state.phase, ChecklistCaretPromptPhase.hidden);
  });

  test('dismissal survives passive changes until an eligible editor tap', () {
    final controller = ChecklistCaretPromptController();
    addTearDown(controller.dispose);
    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    controller.markLayoutReady();

    controller.dismissUntilNextEligibleTap();
    controller.updateBlock(eligible);
    controller.updateInteraction(hasFocus: false, hasCollapsedSelection: true);
    controller.updateInteraction(hasFocus: true, hasCollapsedSelection: true);
    controller.requestLayout();
    expect(
      controller.state.phase,
      ChecklistCaretPromptPhase.dismissedUntilNextEligibleTap,
    );

    controller.onEditorTap(
      block: null,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    controller.onEditorTap(
      block: ineligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    expect(
      controller.state.phase,
      ChecklistCaretPromptPhase.dismissedUntilNextEligibleTap,
    );

    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    expect(controller.state.phase, ChecklistCaretPromptPhase.waitingForLayout);
  });

  test('records typed ineligibility', () {
    final controller = ChecklistCaretPromptController();
    addTearDown(controller.dispose);

    controller.onEditorTap(
      block: ineligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );

    expect(controller.state.phase, ChecklistCaretPromptPhase.ineligible);
    expect(
      controller.state.block?.failureReason,
      ChecklistDeltaFailureReason.incompatibleBlock,
    );
  });

  test('bounds unavailable layout retries and resets them on a new tap', () {
    final controller = ChecklistCaretPromptController(maxLayoutAttempts: 3);
    addTearDown(controller.dispose);
    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );

    expect(controller.markLayoutUnavailable(), isTrue);
    expect(controller.markLayoutUnavailable(), isTrue);
    expect(controller.markLayoutUnavailable(), isFalse);
    expect(controller.state.layoutAttempts, 3);

    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    expect(controller.state.layoutAttempts, 0);
  });
}
