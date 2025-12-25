import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart' as fcp;

Future<Color?> colorPicker(
  BuildContext context,
  String title,
  Color? currentColor,
) {
  return showDialog<Color>(
    context: context,
    builder: (context) {
      return AppColorPickerDialog(
        title: title,
        currentColor: currentColor,
        onColorSelected: (color) {
          AppState.addRecentColor(color);
          Navigator.of(context).pop(color);
        },
      );
    },
  );
}

class AppColorPickerDialog extends StatefulWidget {
  final String title;
  final Color? currentColor;
  final ValueChanged<Color> onColorSelected;

  const AppColorPickerDialog({
    super.key,
    this.title = 'Select Color',
    this.currentColor,
    required this.onColorSelected,
  });

  @override
  State<AppColorPickerDialog> createState() => _AppColorPickerDialogState();
}

class _AppColorPickerDialogState extends State<AppColorPickerDialog> {
  late Color _tempColor;

  @override
  void initState() {
    super.initState();
    _tempColor = widget.currentColor ?? Colors.black;
    if (_tempColor.a == 0) {
      _tempColor = Colors.white;
    } else {
      _tempColor = _tempColor.withValues(alpha: 1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recentColors = AppState.recentColors;

    return Dialog(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              if (recentColors.isNotEmpty) ...[
                const Text(
                  'Recent',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: recentColors.map((color) {
                    return GestureDetector(
                      onTap: () => widget.onColorSelected(color),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.grey.shade300,
                            width: 1,
                          ),
                          boxShadow: [
                            if (widget.currentColor == color)
                              BoxShadow(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.4),
                                spreadRadius: 2,
                                blurRadius: 4,
                              ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
              ],
              const Text(
                'Custom',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 8),
              fcp.ColorPicker(
                pickerColor: _tempColor,
                onColorChanged: (color) {
                  setState(() {
                    _tempColor = color;
                  });
                },
                enableAlpha: false,
                displayThumbColor: true,
                pickerAreaHeightPercent: 0.7,
                portraitOnly: true,
                labelTypes: const [], // Hide text inputs to save space
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  ElevatedButton(
                    onPressed: () => widget.onColorSelected(_tempColor),
                    child: const Text('Select'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
