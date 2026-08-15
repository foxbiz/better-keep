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

  test('dismissal survives passive changes and clears on the next tap', () {
    final controller = ChecklistCaretPromptController();
    addTearDown(controller.dispose);
    controller.onEditorTap(
      block: eligible,
      hasFocus: true,
      hasCollapsedSelection: true,
    );
    controller.markLayoutReady();
    controller.dismissUntilNextTap();

    controller.updateInteraction(hasFocus: false, hasCollapsedSelection: true);
    controller.updateInteraction(hasFocus: true, hasCollapsedSelection: true);
    controller.updateBlock(eligible);
    expect(
      controller.state.phase,
      ChecklistCaretPromptPhase.dismissedUntilNextTap,
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
