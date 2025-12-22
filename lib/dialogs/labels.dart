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
        title: Text("Labels"),
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
            child: Text('OK'),
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

    if (widget.mode == Labels.labelsModeManage) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newLabelController,
                  focusNode: _newLabelFocusNode,
                  decoration: InputDecoration(
                    hintText: 'New label name',
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
                tooltip: 'Add label',
              ),
            ],
          ),
        ),
      );
      children.add(Divider(height: 1));
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
        title: Text(label.name),
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
      leading: Icon(Icons.label),
      title: Text(label.name),
      onTap: () async {
        final newName = await prompt(
          context,
          title: "Edit ${label.name}",
          placeholder: 'Enter new name',
          currentText: label.name,
        );
        if (newName == null || newName.isEmpty) {
          return;
        }

        label.name = newName;
        label.save();
      },
      trailing: IconButton(
        icon: Icon(Icons.delete),
        onPressed: () async {
          var confirmation = await showDeleteDialog(
            context,
            title: "Delete Label",
            message:
                "Are you sure you want to delete this label (${label.name})?",
          );
          if (confirmation == true) {
            label.delete();
          }
        },
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
  }
}
