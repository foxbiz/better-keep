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
  List<String>? selectedLabels;

  return showDialog<List<String>?>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(context.l10n.labels),
        content: Labels(
          selectedLabels: initiallySelected,
          mode: mode,
          onSelect: mode == Labels.labelsModeSelect
              ? (labels) {
                  selectedLabels = labels;
                }
              : null,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, selectedLabels),
            child: Text(context.l10n.ok),
          ),
        ],
      );
    },
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

  @override
  void initState() {
    selectedLabels = widget.selectedLabels ?? [];

    Label.get()
        .then(
          (fetchedLabels) => setState(() {
            labels = fetchedLabels;
          }),
        )
        .catchError((e) {
          // Handle error gracefully
          setState(() {
            labels = [];
          });
        });

    _labelsUpdate = (event) {
      setState(() {
        if (event.event == "created") {
          labels = [event.label, ...(labels ?? [])];
        } else if (event.event == "deleted") {
          labels = labels!
              .where((label) => label.id != event.label.id)
              .toList();
        } else if (event.event == "updated") {
          final index = labels!.indexWhere(
            (label) => label.id == event.label.id,
          );
          if (index != -1) {
            labels![index] = event.label;
          }
        }
      });
    };

    Label.on("changed", _labelsUpdate);
    super.initState();
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

    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: 300,
        maxWidth: 320,
        maxHeight: maxHeight,
      ),
      child: _buildBody(),
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

          if (widget.onSelect != null) {
            widget.onSelect!(selectedLabels);
          }
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
              controller: _newLabelController,
              focusNode: _newLabelFocusNode,
              decoration: InputDecoration(
                hintText: context.l10n.newLabelName,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              onSubmitted: (_) => _addLabelFromInput(),
            ),
          ),
          SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.add),
            onPressed: _addLabelFromInput,
            tooltip: context.l10n.addLabel,
          ),
        ],
      ),
    );
  }

  void _addLabelFromInput() {
    final labelName = _newLabelController.text.trim();
    if (labelName.isEmpty) return;
    final label = Label(name: labelName);
    label.save();
    _newLabelController.clear();
    _newLabelFocusNode.requestFocus();

    // Auto-select the newly created label in select mode
    if (widget.mode == Labels.labelsModeSelect) {
      selectedLabels.add(labelName);
      if (widget.onSelect != null) {
        widget.onSelect!(selectedLabels);
      }
    }
  }
}
