import 'package:better_keep/models/label.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';

class Labels extends StatefulWidget {
  final Function(List<Label>) onSelect;
  const Labels({super.key, required this.onSelect});

  @override
  State<Labels> createState() => _LabelsState();
}

class _LabelsState extends State<Labels> {
  List<Label> _labels = [];
  final List<String> _selectedLabels = [];

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
    AppState.subscribe("notes_view_mode", _onViewModeChanged);
    super.initState();
  }

  @override
  void dispose() {
    Label.off("changed", _labelsListener);
    AppState.unsubscribe("notes_view_mode", _onViewModeChanged);
    super.dispose();
  }

  void _onViewModeChanged(dynamic value) {
    if (!mounted) return;
    if (value is! NoteViewMode) return;
    setState(() {
      _selectedLabels.clear();
    });
    // Notify parent to reset the notes filter
    widget.onSelect([]);
  }

  void _clearSelection() {
    setState(() {
      _selectedLabels.clear();
    });
    widget.onSelect([]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasSelection = _selectedLabels.isNotEmpty;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (_labels.isNotEmpty) ...[
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              alignment: Alignment.centerLeft,
              child: hasSelection
                  ? Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: AnimatedOpacity(
                        opacity: hasSelection ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 150),
                        child: ActionChip(
                          avatar: Icon(
                            Icons.close,
                            size: 18,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          label: Text('Clear'),
                          onPressed: _clearSelection,
                          backgroundColor: colorScheme.surfaceContainerHighest,
                          side: BorderSide.none,
                          labelStyle: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            ..._labels.asMap().entries.map((entry) {
              final index = entry.key;
              final label = entry.value;
              final isSelected = _selectedLabels.contains(label.name);
              return Padding(
                padding: EdgeInsets.only(
                  right: index < _labels.length - 1 ? 8 : 0,
                ),
                child: FilterChip(
                  selected: isSelected,
                  label: Text(label.name),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _selectedLabels.add(label.name);
                      } else {
                        _selectedLabels.remove(label.name);
                      }
                    });

                    Future.microtask(
                      () => widget.onSelect(
                        _labels
                            .where((lbl) => _selectedLabels.contains(lbl.name))
                            .toList(),
                      ),
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
        ],
      ),
    );
  }
}
