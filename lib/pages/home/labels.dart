import 'package:better_keep/models/label.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/material.dart';

class Labels extends StatefulWidget {
  final Function(List<Label>) onSelect;
  final List<String> selectedLabels;
  const Labels({
    super.key,
    required this.onSelect,
    this.selectedLabels = const [],
  });

  @override
  State<Labels> createState() => _LabelsState();
}

class _LabelsState extends State<Labels> {
  List<Label> _labels = [];

  void _labelsListener(LabelEvent event) {
    setState(() {
      if (event.event == "created") {
        _labels = [event.label, ...(_labels)];
      } else if (event.event == "deleted") {
        _labels = _labels.where((label) => label.id != event.label.id).toList();
      } else if (event.event == "updated") {
        final index = _labels.indexWhere((label) => label.id == event.label.id);
        if (index != -1) {
          _labels[index] = event.label;
        }
      }
    });
  }

  @override
  void initState() {
    Label.get().then((fetchedLabels) {
      if (mounted) {
        setState(() {
          _labels = fetchedLabels;
        });
      }
    });
    Label.on("changed", _labelsListener);
    super.initState();
  }

  @override
  void dispose() {
    Label.off("changed", _labelsListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          ..._labels.asMap().entries.map((entry) {
            final index = entry.key;
            final label = entry.value;
            final isSelected = widget.selectedLabels.contains(label.name);
            return Padding(
              padding: EdgeInsets.only(
                right: index < _labels.length - 1 ? 8 : 0,
              ),
              child: FilterChip(
                selected: isSelected,
                label: Text(label.displayName(context.l10n)),
                onSelected: (selected) {
                  final selectedNames = widget.selectedLabels.toSet();
                  if (selected) {
                    selectedNames.add(label.name);
                  } else {
                    selectedNames.remove(label.name);
                  }
                  widget.onSelect(
                    _labels
                        .where((lbl) => selectedNames.contains(lbl.name))
                        .toList(),
                  );
                },
                showCheckmark: false,
                avatar: isSelected
                    ? Icon(Icons.check, size: 18)
                    : Icon(Icons.label_outline, size: 18),
                backgroundColor: colorScheme.surfaceContainerHighest,
                selectedColor: colorScheme.primaryContainer,
                labelStyle: TextStyle(
                  color: isSelected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
                side: BorderSide.none,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            );
          }),
        ],
      ),
    );
  }
}
