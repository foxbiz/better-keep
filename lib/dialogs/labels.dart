import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/dialogs/prompt.dart';
import 'package:better_keep/dialogs/delete_dialog.dart';
import 'package:better_keep/models/label.dart';

/// Shows a dialog for managing labels.
/// [mode] determines the manage or select mode.
Future<List<String>?> labels(
  BuildContext context, {
  List<String>? initiallySelected,
  int mode = Labels.labelsModeManage,
}) {
  return showDialog<List<String>?>(
    context: context,
    builder: (context) => Labels(selectedLabels: initiallySelected, mode: mode),
  );
}

class Labels extends StatefulWidget {
  final int mode;
  final List<String>? selectedLabels;
  static const int labelsModeManage = 0;
  static const int labelsModeSelect = 1;
  final Function(List<String>)? onSelect;
  const Labels({
    super.key,
    this.mode = labelsModeManage,
    this.onSelect,
    this.selectedLabels,
  });
  @override
  State<Labels> createState() => _LabelsState();
}

class _LabelsState extends State<Labels> {
  List<Label>? labels;
  late List<String> selectedLabels;
  late final Function(LabelEvent) _labelsUpdate;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _newLabelController = TextEditingController();
  final FocusNode _newLabelFocusNode = FocusNode();
  bool _selectionChanged = false;
  bool _submitting = false;
  bool _saveFailed = false;

  @override
  void initState() {
    super.initState();
    selectedLabels = widget.selectedLabels?.toSet().toList() ?? [];

    Label.get()
        .then((fetchedLabels) {
          if (!mounted) return;
          setState(() {
            labels = fetchedLabels;
          });
        })
        .catchError((e) {
          if (!mounted) return;
          setState(() {
            labels = [];
          });
        });

    _labelsUpdate = (event) {
      if (!mounted) return;
      setState(() {
        if (event.event == "created") {
          labels = [event.label, ...(labels ?? [])];
        } else if (event.event == "deleted") {
          labels = (labels ?? [])
              .where((label) => label.id != event.label.id)
              .toList();
        } else if (event.event == "updated") {
          final index = (labels ?? []).indexWhere(
            (label) => label.id == event.label.id,
          );
          if (index != -1) {
            labels![index] = event.label;
          }
        }
      });
    };

    Label.on("changed", _labelsUpdate);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _newLabelController.dispose();
    _newLabelFocusNode.dispose();
    Label.off("changed", _labelsUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double maxHeight = MediaQuery.of(context).size.height * 0.6;

    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        title: Text(context.l10n.labels),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 300,
            maxWidth: 320,
            maxHeight: maxHeight,
          ),
          child: AbsorbPointer(absorbing: _submitting, child: _buildBody()),
        ),
        actions: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: _submitting
                ? null
                : () => _submit(closeAfterSaving: true),
            child: Text(context.l10n.ok),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (labels == null) {
      return SizedBox(
        height: 100,
        child: Center(
          child: CircularProgressIndicator(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }

    List<Widget> children = [];

    // Show new label input in both manage mode and select mode
    children.add(_buildNewLabelInput());
    children.add(Divider(height: 1));

    // Show empty state message when no labels exist
    if (labels!.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.label_outline,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              SizedBox(height: 12),
              Text(
                context.l10n.noLabelsYet,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(height: 4),
              Text(
                context.l10n.createLabelToOrganize,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      );
    }

    for (int i = 0; i < labels!.length; i++) {
      children.add(_buildLabelTile(labels![i]));
      if (i < labels!.length - 1) {
        children.add(Divider(height: 1));
      }
    }

    return Scrollbar(
      thumbVisibility: true,
      controller: _scrollController,
      child: SingleChildScrollView(
        controller: _scrollController,
        physics: BouncingScrollPhysics(),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  Widget _buildLabelTile(Label label) {
    if (widget.mode == Labels.labelsModeSelect) {
      bool isSelected = selectedLabels.contains(label.name);
      return ListTile(
        leading: isSelected ? Icon(Icons.check) : Icon(Icons.label),
        title: Text(label.displayName(context.l10n)),
        onTap: () {
          if (selectedLabels.contains(label.name)) {
            selectedLabels.remove(label.name);
          } else {
            selectedLabels.add(label.name);
          }
          setState(() {});

          _notifySelection();
        },
      );
    }

    return ListTile(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      leading: Icon(label.isSystem ? Icons.lock_outline : Icons.label),
      title: Text(label.displayName(context.l10n)),
      onTap: label.isSystem
          ? null
          : () async {
              final newName = await prompt(
                context,
                title: context.l10n.editLabelName(
                  label.displayName(context.l10n),
                ),
                placeholder: context.l10n.enterNewName,
                currentText: label.name,
              );
              if (newName == null || newName.isEmpty) {
                return;
              }

              label.name = newName;
              label.save();
            },
      trailing: label.isSystem
          ? null
          : IconButton(
              icon: Icon(Icons.delete),
              onPressed: () async {
                var confirmation = await showDeleteDialog(
                  context,
                  title: context.l10n.deleteLabel,
                  message: context.l10n.deleteLabelConfirmation(
                    label.displayName(context.l10n),
                  ),
                );
                if (confirmation == true) {
                  label.delete();
                }
              },
            ),
    );
  }

  Widget _buildNewLabelInput() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              readOnly: _submitting,
              controller: _newLabelController,
              focusNode: _newLabelFocusNode,
              decoration: InputDecoration(
                hintText: context.l10n.newLabelName,
                errorText: _saveFailed ? context.l10n.couldNotSaveLabel : null,
                errorMaxLines: 3,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.add),
            onPressed: _submitting ? null : () => _submit(),
            tooltip: context.l10n.addLabel,
          ),
        ],
      ),
    );
  }

  void _notifySelection() {
    _selectionChanged = true;
    widget.onSelect?.call(List.of(selectedLabels));
  }

  void _acceptSelection() {
    Navigator.pop(
      context,
      widget.mode == Labels.labelsModeSelect && _selectionChanged
          ? List.of(selectedLabels)
          : null,
    );
  }

  Future<void> _submit({bool closeAfterSaving = false}) async {
    if (_submitting) return;
    final labelName = _newLabelController.text.trim();
    if (labelName.isEmpty) {
      if (closeAfterSaving) _acceptSelection();
      return;
    }

    setState(() {
      _submitting = true;
      _saveFailed = false;
    });
    try {
      var existing = await Label.findByName(labelName);
      if (!mounted) return;
      if (existing == null && closeAfterSaving) {
        var answered = false;
        void respond(BuildContext context, bool confirmed) {
          if (answered) return;
          answered = true;
          Navigator.pop(context, confirmed);
        }

        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            content: Text(
              widget.mode == Labels.labelsModeSelect
                  ? context.l10n.createAndApplyLabelConfirmation(labelName)
                  : context.l10n.createLabelConfirmation(labelName),
            ),
            actions: [
              TextButton(
                onPressed: () => respond(context, false),
                child: Text(context.l10n.cancel),
              ),
              TextButton(
                onPressed: () => respond(context, true),
                child: Text(context.l10n.addLabel),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
        // A label may have arrived through sync while confirmation was open.
        existing = await Label.findByName(labelName);
        if (!mounted) return;
      }
      if (existing == null) {
        await Label(name: labelName).save();
      }
      if (!mounted) return;

      if (widget.mode == Labels.labelsModeSelect &&
          !selectedLabels.contains(labelName)) {
        selectedLabels.add(labelName);
        _notifySelection();
      }
      _newLabelController.clear();
      if (closeAfterSaving) {
        _acceptSelection();
      } else {
        _newLabelFocusNode.requestFocus();
      }
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
