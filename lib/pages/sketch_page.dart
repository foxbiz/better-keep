// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:better_keep/components/page_pattern_painter.dart';
import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/components/sketch_tool_popup.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as path;
import 'package:better_keep/components/adaptive_toolbar.dart';
import 'package:better_keep/dialogs/delete_dialog.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/dialogs/color_picker.dart';
import 'package:perfect_freehand/perfect_freehand.dart';

const Size kA4Size = Size(794, 1123); // A4 at 96 DPI

class SketchPage extends StatefulWidget {
  final Note note;
  final SketchData sketch;
  final NoteAttachment? sourceAttachment;
  final String? heroTag;

  /// Index of the current sketch in note.sketches list, used for pagination
  final int? initialIndex;

  const SketchPage({
    super.key,
    required this.sketch,
    required this.note,
    this.sourceAttachment,
    this.heroTag,
    this.initialIndex,
  });

  @override
  State<SketchPage> createState() => _SketchPageState();
}

class _SketchPageState extends State<SketchPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final TransformationController _transformationController =
      TransformationController();

  late Color _selectedColor;
  late Color _paperColor;
  late Color _backgroundColor;
  late Color _foregroundColor;

  int _undoCount = 0;
  final List<SketchStroke> _redoStack = [];

  // Animation controllers
  late AnimationController _toolbarAnimationController;
  late Animation<Offset> _toolbarSlideAnimation;
  late Animation<double> _toolbarFadeAnimation;
  bool _isToolbarVisible = true;

  bool _hasFitted = false;
  SketchTool _selectedTool = SketchTool.pen;

  int _activePointerCount = 0;
  bool _isMultiTouch = false;

  Timer? _autoSaveTimer;
  double _penSize = 5.0;
  double _eraserSize = 20.0;
  SketchStroke? _currentStroke;
  List<SketchStroke> _strokes = [];
  ui.Image? _loadedBackgroundImage;
  Size _canvasSize = kA4Size;
  bool _isImageBasedSketch = false;
  final bool _isDeleted = false;
  bool _isDirty = false;
  Offset? _cursorPosition;
  bool _isMouseInput = false;

  /// Cache for loaded background images to avoid re-reading from OPFS
  /// Key: image path, Value: decoded ui.Image
  static final Map<String, ui.Image> _backgroundImageCache = {};
  static const int _maxImageCacheSize = 10;

  /// Debounce timer for save operations during rapid sketch switching
  Timer? _debounceSaveTimer;

  /// Captured state for pending debounced save
  _PendingSaveState? _pendingSaveState;

  late SketchData _sketchData;
  int _currentSketchIndex = 0;
  SketchData?
  _pendingNewSketch; // Stores unsaved new sketch when navigating away

  /// Local copy of sketches for smooth navigation
  /// This is independent of widget.note.sketches to prevent UI flicker when note updates
  late List<SketchData> _localSketches;

  /// Get total number of sketches (local sketches plus pending new sketch if any)
  int get _totalSketches =>
      _localSketches.length + (_pendingNewSketch != null ? 1 : 0);

  /// Check if pagination should be shown
  /// Show when there are multiple sketches OR when viewing existing sketches with a new unsaved one
  bool get _showPagination => _totalSketches > 1;

  @override
  void initState() {
    super.initState();

    // Initialize toolbar animation controller
    _toolbarAnimationController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _toolbarSlideAnimation =
        Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _toolbarAnimationController,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        );
    _toolbarFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _toolbarAnimationController,
        curve: Curves.easeOut,
      ),
    );
    // Start with toolbar visible
    _toolbarAnimationController.forward();

    // Initialize local sketches from note - this won't change when note updates
    _localSketches = List<SketchData>.from(widget.note.sketches);

    _sketchData = widget.sketch;
    // Initialize sketch index from parameter or find it in the list
    // For new sketches (not yet in the list), indexOf returns -1, so we default to 0
    final existingIndex = _localSketches.indexOf(_sketchData);
    _currentSketchIndex =
        widget.initialIndex ?? (existingIndex >= 0 ? existingIndex : 0);

    // An image-based sketch either comes from a source image attachment,
    // or is a sketch that was previously converted from an image (has backgroundImage)
    _isImageBasedSketch =
        widget.sourceAttachment?.type == AttachmentType.image ||
        (_sketchData.backgroundImage != null &&
            _sketchData.backgroundImage!.isNotEmpty);

    // For image-based sketches, use the stored aspect ratio to set initial canvas size
    // This prevents the hero animation from stretching to A4 and snapping back
    if (_isImageBasedSketch && _sketchData.aspectRatio > 0) {
      // Use A4 width as base and calculate height from aspect ratio
      _canvasSize = Size(
        kA4Size.width,
        kA4Size.width / _sketchData.aspectRatio,
      );
    }

    _strokes = List<SketchStroke>.from(_sketchData.strokes);
    _paperColor = _isImageBasedSketch
        ? Colors.transparent
        : _sketchData.backgroundColor;
    _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;

    if (_sketchData.backgroundImage != null) {
      _loadBackgroundImage();
    }
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _backgroundColor = widget.note.color == Colors.transparent
        ? Theme.of(context).colorScheme.surface
        : widget.note.color;

    _foregroundColor = isDark(_backgroundColor) ? Colors.white : Colors.black;
  }

  @override
  void dispose() {
    _toolbarAnimationController.dispose();
    _transformationController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _autoSaveTimer?.cancel();
    // Flush any pending debounced save immediately
    _flushPendingSave();
    super.dispose();
  }

  /// Toggle toolbar visibility with animation
  void _toggleToolbar() {
    setState(() {
      _isToolbarVisible = !_isToolbarVisible;
    });
    if (_isToolbarVisible) {
      _toolbarAnimationController.forward();
    } else {
      _toolbarAnimationController.reverse();
    }
  }

  /// Immediately execute any pending debounced save
  void _flushPendingSave() {
    _debounceSaveTimer?.cancel();
    _debounceSaveTimer = null;
    if (_pendingSaveState != null) {
      _executePendingSave(_pendingSaveState!);
      _pendingSaveState = null;
    }
  }

  /// Queue a save operation with debouncing
  /// Captures current sketch state and schedules save after delay
  void _queueDebouncedSave() {
    // Flush any previous pending save first to prevent state mixup
    // This ensures each sketch's state is saved before we overwrite _pendingSaveState
    if (_pendingSaveState != null) {
      // Cancel the timer since we're executing immediately
      _debounceSaveTimer?.cancel();
      _debounceSaveTimer = null;
      _executePendingSave(_pendingSaveState!).catchError((e) {
        AppLogger.error('Error flushing previous save', e);
      });
      _pendingSaveState = null;
    }

    // Capture current state before it changes
    _pendingSaveState = _PendingSaveState(
      sketchData: _sketchData,
      strokes: List<SketchStroke>.from(_strokes),
      paperColor: _paperColor,
      canvasSize: _canvasSize,
      isImageBasedSketch: _isImageBasedSketch,
      loadedBackgroundImage: _loadedBackgroundImage,
      note: widget.note,
      sourceAttachment: widget.sourceAttachment,
      localSketches: _localSketches,
      onIndexUpdate: (index) {
        if (mounted) {
          setState(() => _currentSketchIndex = index);
        }
      },
    );

    // Start new timer for this save
    _debounceSaveTimer = Timer(const Duration(milliseconds: 300), () {
      if (_pendingSaveState != null) {
        _executePendingSave(_pendingSaveState!).catchError((e) {
          if (mounted) {
            snackbar('Error saving sketch: $e', Colors.red);
          }
        });
        _pendingSaveState = null;
      }
    });
  }

  /// Execute the pending save with captured state
  Future<void> _executePendingSave(_PendingSaveState state) async {
    try {
      if (state.strokes.isEmpty) {
        if (state.note.hasSketch(state.sketchData)) {
          state.note.removeSketch(state.sketchData);
        }
        return;
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final bodySize = state.canvasSize;

      // Draw background
      if (state.isImageBasedSketch) {
        canvas.drawColor(Colors.transparent, BlendMode.clear);
      } else {
        canvas.drawColor(state.paperColor, BlendMode.src);
      }

      if (state.loadedBackgroundImage != null) {
        paintImage(
          canvas: canvas,
          rect: Offset.zero & bodySize,
          image: state.loadedBackgroundImage!,
          fit: state.isImageBasedSketch ? BoxFit.fill : BoxFit.contain,
        );
      }

      // Draw page pattern
      if (!state.isImageBasedSketch &&
          state.sketchData.pagePattern != PagePattern.blank) {
        final patternPainter = PagePatternPainter(
          pattern: state.sketchData.pagePattern,
          lineColor: isDark(state.paperColor)
              ? Colors.white.withValues(alpha: 0.25)
              : Colors.black.withValues(alpha: 0.18),
        );
        patternPainter.paint(canvas, bodySize);
      }

      // Draw strokes
      final painter = SketchPainter(strokes: state.strokes);
      painter.paint(canvas, bodySize);

      final picture = recorder.endRecording();
      final img = await picture.toImage(
        bodySize.width.toInt(),
        bodySize.height.toInt(),
      );
      final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);

      if (pngBytes == null) {
        throw 'Failed to encode sketch image';
      }

      final compressedBytes = await _compressSketchPreview(
        pngBytes.buffer.asUint8List(),
      );

      final fs = await fileSystem();
      String previewPath = path.join(
        await fs.documentDir,
        'sketches',
        '${DateTime.now().millisecondsSinceEpoch}_preview.jpg',
      );
      // Fire and forget - don't await file write to prevent OPFS blocking UI
      writeEncryptedBytes(previewPath, compressedBytes).catchError((e) {
        AppLogger.error('Error writing preview', e);
      });

      state.sketchData.strokes = state.strokes;
      state.sketchData.backgroundColor = state.paperColor;
      state.sketchData.previewImage = previewPath;
      state.sketchData.aspectRatio = bodySize.width / bodySize.height;

      if (state.isImageBasedSketch && state.sourceAttachment != null) {
        state.sourceAttachment!.type = AttachmentType.sketch;
        state.sourceAttachment!.sketch = state.sketchData;
        state.sourceAttachment!.image = null;
        state.note.save();
        if (!state.localSketches.contains(state.sketchData)) {
          state.localSketches.add(state.sketchData);
        }
      } else if (!state.note.hasSketch(state.sketchData)) {
        state.note.addSketch(state.sketchData);
        if (!state.localSketches.contains(state.sketchData)) {
          state.localSketches.add(state.sketchData);
          state.onIndexUpdate?.call(
            state.localSketches.indexOf(state.sketchData),
          );
        }
      } else {
        state.note.save();
      }
    } catch (e) {
      AppLogger.error('Error in debounced save', e);
      rethrow;
    }
  }

  /// Navigate to a different sketch by index
  void _navigateToSketch(int index) {
    if (index < 0 || index >= _totalSketches) return;
    if (index == _currentSketchIndex) return;

    final savedSketchCount = _localSketches.length;
    final isCurrentlyOnPendingSketch =
        _pendingNewSketch != null && _currentSketchIndex >= savedSketchCount;

    // Only save if there are actual changes (dirty) and has content
    if (_isDirty && _strokes.isNotEmpty) {
      // Queue debounced save - captures state and saves after delay
      _queueDebouncedSave();
      // Only clear pending if we just saved the pending sketch (it's now in _localSketches)
      if (isCurrentlyOnPendingSketch) {
        _pendingNewSketch = null;
      }
      _isDirty = false; // Mark as not dirty since save is queued
    }
    // If on empty pending sketch, keep it stored so we can navigate back

    // Check if navigating to the pending new sketch position
    final isNavigatingToPendingSketch = index >= _localSketches.length;

    if (isNavigatingToPendingSketch && _pendingNewSketch != null) {
      // Navigate to the pending new sketch
      setState(() {
        _currentSketchIndex = index;
        _sketchData = _pendingNewSketch!;
        _strokes = List<SketchStroke>.from(_sketchData.strokes);
        _undoCount = 0;
        _redoStack.clear();
        _isDirty = false;
        _isImageBasedSketch = false;
        _paperColor = _sketchData.backgroundColor;
        _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;
        _canvasSize = kA4Size;
        _loadedBackgroundImage = null;
        _hasFitted = false;
      });
      return;
    }

    if (isNavigatingToPendingSketch) {
      // No pending sketch to navigate to
      return;
    }

    final newSketch = _localSketches[index];

    // Check if background image is cached for instant display
    final bgPath = newSketch.backgroundImage;
    final cachedBgImage = bgPath != null ? _backgroundImageCache[bgPath] : null;

    setState(() {
      _currentSketchIndex = index;
      _sketchData = newSketch;
      _strokes = List<SketchStroke>.from(_sketchData.strokes);
      _undoCount = 0;
      _redoStack.clear();
      _isDirty = false;
      // Don't clear _pendingNewSketch here - keep it so we can navigate back

      // Update image-based sketch flag
      _isImageBasedSketch =
          _sketchData.backgroundImage != null &&
          _sketchData.backgroundImage!.isNotEmpty;

      // Update paper color
      _paperColor = _isImageBasedSketch
          ? Colors.transparent
          : _sketchData.backgroundColor;
      _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;

      // Use cached background image if available for instant render
      if (cachedBgImage != null) {
        _loadedBackgroundImage = cachedBgImage;
        _canvasSize = Size(
          cachedBgImage.width.toDouble(),
          cachedBgImage.height.toDouble(),
        );
      } else if (_isImageBasedSketch && _sketchData.aspectRatio > 0) {
        // Fallback to aspect ratio while loading
        _loadedBackgroundImage = null;
        _canvasSize = Size(
          kA4Size.width,
          kA4Size.width / _sketchData.aspectRatio,
        );
      } else {
        _loadedBackgroundImage = null;
        _canvasSize = kA4Size;
      }

      _hasFitted = false;
    });

    // Load background image if present and not cached
    if (_sketchData.backgroundImage != null && cachedBgImage == null) {
      _loadBackgroundImage();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _save();
    }
  }

  /// Delete the current sketch and navigate to next or previous
  Future<void> _deleteCurrentSketch() async {
    final confirm = await showDeleteDialog(context, title: 'Delete Sketch?');

    if (confirm != true) return;

    final isOnPendingSketch = _pendingNewSketch == _sketchData;

    if (isOnPendingSketch) {
      // Just clear the pending sketch
      _pendingNewSketch = null;

      if (_localSketches.isEmpty) {
        // No other sketches, close the page
        Navigator.pop(context);
        return;
      }

      // Navigate to the last saved sketch
      _navigateToSketch(_localSketches.length - 1);
      return;
    }

    // Remove from local sketches
    final deletedIndex = _localSketches.indexOf(_sketchData);
    if (deletedIndex >= 0) {
      _localSketches.removeAt(deletedIndex);
    }

    // Remove from note
    widget.note.removeSketch(_sketchData);

    // Determine where to navigate
    if (_localSketches.isEmpty && _pendingNewSketch == null) {
      // No sketches left, close the page
      Navigator.pop(context);
      return;
    }

    // Navigate to next sketch if available, otherwise previous
    int newIndex;
    if (_pendingNewSketch != null) {
      // Go to pending new sketch
      newIndex = _localSketches.length;
    } else if (deletedIndex < _localSketches.length) {
      // Next sketch exists at same index
      newIndex = deletedIndex;
    } else {
      // Go to previous sketch
      newIndex = _localSketches.length - 1;
    }

    // Load the new sketch
    final newSketch = newIndex < _localSketches.length
        ? _localSketches[newIndex]
        : _pendingNewSketch!;

    setState(() {
      _currentSketchIndex = newIndex;
      _sketchData = newSketch;
      _strokes = List<SketchStroke>.from(_sketchData.strokes);
      _undoCount = 0;
      _redoStack.clear();
      _isDirty = false;

      _isImageBasedSketch =
          _sketchData.backgroundImage != null &&
          _sketchData.backgroundImage!.isNotEmpty;

      _paperColor = _isImageBasedSketch
          ? Colors.transparent
          : _sketchData.backgroundColor;
      _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;

      if (_isImageBasedSketch && _sketchData.aspectRatio > 0) {
        _canvasSize = Size(
          kA4Size.width,
          kA4Size.width / _sketchData.aspectRatio,
        );
      } else {
        _canvasSize = kA4Size;
      }

      _loadedBackgroundImage = null;
      _hasFitted = false;
    });

    if (_sketchData.backgroundImage != null) {
      _loadBackgroundImage();
    }
  }

  /// Create a new blank sketch
  void _createNewSketch() async {
    // Save current sketch first if it has strokes
    if (_strokes.isNotEmpty) {
      await _save();
      // Clear pending since we just saved
      _pendingNewSketch = null;
    }

    // Create new sketch data
    final newSketch = SketchData(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
    );

    setState(() {
      _pendingNewSketch = newSketch;
      _sketchData = newSketch;
      _strokes = [];
      _undoCount = 0;
      _redoStack.clear();
      _isDirty = false;
      _isImageBasedSketch = false;
      _paperColor = newSketch.backgroundColor;
      _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;
      _canvasSize = kA4Size;
      _loadedBackgroundImage = null;
      _hasFitted = false;
      // New sketch is at the end (after all local sketches)
      _currentSketchIndex = _localSketches.length;
    });
  }

  void paintCanvas(Canvas canvas, Size size) {
    for (final stroke in _strokes) {
      final outlinePoints = getStroke(
        SketchStroke.parsePoints(stroke.points),
        options: StrokeOptions(
          size: stroke.size,
          thinning: 0.5,
          smoothing: 0.5,
          streamline: 0.5,
          isComplete: true,
        ),
      );

      final path = Path();
      if (outlinePoints.isEmpty) continue;

      path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);
      for (int i = 1; i < outlinePoints.length; i++) {
        path.lineTo(outlinePoints[i].dx, outlinePoints[i].dy);
      }
      path.close();

      canvas.drawPath(
        path,
        Paint()
          ..color = stroke.tool == SketchTool.eraser
              ? Colors.white
              : stroke
                    .color // Eraser logic needs improvement for non-white bg
          ..style = PaintingStyle.fill
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        // Capture all data needed for save before popping
        // This allows the save to complete even after widget disposes
        _saveInBackground();
        if (didPop) return;
        // If we came from image viewer and saved strokes, pop twice to skip the image viewer
        if (widget.sourceAttachment != null && _strokes.isNotEmpty) {
          Navigator.of(context).pop();
          Navigator.of(context).pop();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: _backgroundColor,
        appBar: AppBar(
          backgroundColor: _backgroundColor,
          foregroundColor: _foregroundColor,
          iconTheme: IconThemeData(color: _foregroundColor),
          actionsIconTheme: IconThemeData(color: _foregroundColor),
          leading: BackButton(color: _foregroundColor),
          titleTextStyle: TextStyle(
            color: _foregroundColor,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
          actions: [
            // Add new sketch button
            IconButton(
              icon: const Icon(Icons.add),
              color: _foregroundColor,
              onPressed: _createNewSketch,
              tooltip: 'New Sketch',
            ),
            if (!_isImageBasedSketch)
              IconButton(
                icon: const Icon(Icons.color_lens),
                color: _foregroundColor,
                onPressed: () => _pickColor(true),
                tooltip: 'Paper Color',
              ),
            if (!_isImageBasedSketch)
              PopupMenuButton<PagePattern>(
                icon: Icon(
                  _sketchData.pagePattern.icon,
                  color: _foregroundColor,
                ),
                tooltip: 'Page Pattern',
                onSelected: (pattern) {
                  setState(() {
                    _sketchData.pagePattern = pattern;
                    _isDirty = true;
                  });
                },
                itemBuilder: (context) => PagePattern.values.map((pattern) {
                  final isSelected = _sketchData.pagePattern == pattern;
                  return PopupMenuItem(
                    value: pattern,
                    child: Row(
                      children: [
                        Icon(
                          pattern.icon,
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          pattern.displayName,
                          style: isSelected
                              ? TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                )
                              : null,
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            if (_strokes.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.save_alt),
                color: _foregroundColor,
                onPressed: _saveToGallery,
                tooltip: 'Save to Gallery',
              ),
            if (_localSketches.contains(_sketchData) ||
                _pendingNewSketch == _sketchData)
              IconButton(
                icon: const Icon(Icons.delete),
                color: Theme.of(context).colorScheme.error,
                onPressed: _deleteCurrentSketch,
              ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (!_hasFitted) {
                    _hasFitted = true;
                    // Delay fit when hero animation is active to prevent jarring transition
                    if (widget.heroTag != null) {
                      // Set initial centered position immediately (without animation delay)
                      _fitToScreen(constraints.maxWidth, constraints.maxHeight);
                    } else {
                      _fitToScreen(constraints.maxWidth, constraints.maxHeight);
                    }
                  }

                  final canvasWidget = Container(
                    width: _canvasSize.width,
                    height: _canvasSize.height,
                    decoration: _isImageBasedSketch
                        ? null
                        : BoxDecoration(
                            color: _paperColor,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 10,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                    child: Stack(
                      children: [
                        if (_sketchData.backgroundImage != null)
                          Positioned.fill(
                            child: UniversalImage(
                              path: _sketchData.backgroundImage!,
                              fit: BoxFit.contain,
                            ),
                          ),
                        // Page pattern layer - rendered dynamically, not saved in preview
                        if (!_isImageBasedSketch &&
                            _sketchData.pagePattern != PagePattern.blank)
                          Positioned.fill(
                            child: PagePatternBackground(
                              pattern: _sketchData.pagePattern,
                              size: _canvasSize,
                              lineColor: isDark(_paperColor)
                                  ? Colors.white.withValues(alpha: 0.25)
                                  : Colors.black.withValues(alpha: 0.18),
                            ),
                          ),
                        Positioned.fill(
                          child: MouseRegion(
                            cursor: SystemMouseCursors.none,
                            onHover: (event) {
                              setState(() {
                                _cursorPosition = event.localPosition;
                                _isMouseInput = true;
                              });
                            },
                            onExit: (event) {
                              setState(() {
                                _cursorPosition = null;
                              });
                            },
                            child: Listener(
                              onPointerDown: (details) {
                                if (widget.note.readOnly) return;
                                setState(() {
                                  _isMouseInput =
                                      details.kind ==
                                      ui.PointerDeviceKind.mouse;
                                  _cursorPosition = details.localPosition;
                                  _activePointerCount++;
                                  if (_activePointerCount > 1) {
                                    _isMultiTouch = true;
                                    _currentStroke = null;
                                  } else if (!_isMultiTouch) {
                                    _startStroke(
                                      details.localPosition.dx,
                                      details.localPosition.dy,
                                      details.pressure,
                                    );
                                  }
                                });
                              },
                              onPointerMove: (details) {
                                if (widget.note.readOnly) return;
                                setState(() {
                                  _cursorPosition = details.localPosition;
                                });
                                if (_isMultiTouch) return;
                                _updateStroke(
                                  details.localPosition.dx,
                                  details.localPosition.dy,
                                  details.pressure,
                                );
                              },
                              onPointerUp: (details) {
                                if (widget.note.readOnly) return;
                                setState(() {
                                  _activePointerCount--;
                                  if (_activePointerCount == 0) {
                                    _isMultiTouch = false;
                                    _endStroke();
                                    // Hide cursor for touch input when drawing ends
                                    if (!_isMouseInput) {
                                      _cursorPosition = null;
                                    }
                                  }
                                });
                              },
                              onPointerCancel: (details) {
                                if (widget.note.readOnly) return;
                                setState(() {
                                  _activePointerCount--;
                                  if (_activePointerCount == 0) {
                                    _isMultiTouch = false;
                                    _endStroke();
                                    // Hide cursor for touch input when drawing ends
                                    if (!_isMouseInput) {
                                      _cursorPosition = null;
                                    }
                                  }
                                });
                              },
                              child: CustomPaint(
                                painter: SketchPainter(
                                  strokes: [
                                    ..._strokes,
                                    if (_currentStroke != null) _currentStroke!,
                                  ],
                                ),
                                size: Size.infinite,
                              ),
                            ),
                          ),
                        ),
                        // Custom cursor indicator - show for mouse always, for touch only while drawing
                        if (_cursorPosition != null &&
                            (_isMouseInput || _currentStroke != null))
                          Builder(
                            builder: (context) {
                              final toolSize =
                                  _selectedTool == SketchTool.eraser
                                  ? _eraserSize
                                  : _penSize;
                              // Minimum display size for visibility
                              const minDisplaySize = 16.0;
                              final displaySize = toolSize < minDisplaySize
                                  ? minDisplaySize
                                  : toolSize;
                              final isEraser =
                                  _selectedTool == SketchTool.eraser;

                              return Positioned(
                                left: _cursorPosition!.dx - displaySize / 2,
                                top: _cursorPosition!.dy - displaySize / 2,
                                child: IgnorePointer(
                                  child: Container(
                                    width: displaySize,
                                    height: displaySize,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isEraser
                                          ? Colors.white.withValues(alpha: 0.3)
                                          : _selectedColor.withValues(
                                              alpha: 0.4,
                                            ),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.7,
                                        ),
                                        width: 2,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.4,
                                          ),
                                          blurRadius: 0,
                                          spreadRadius: 1,
                                        ),
                                      ],
                                    ),
                                    // Show actual pen size indicator inside when display is larger
                                    child: toolSize < minDisplaySize
                                        ? Center(
                                            child: Container(
                                              width: toolSize,
                                              height: toolSize,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: isEraser
                                                    ? Colors.white.withValues(
                                                        alpha: 0.8,
                                                      )
                                                    : _selectedColor.withValues(
                                                        alpha: 0.8,
                                                      ),
                                              ),
                                            ),
                                          )
                                        : null,
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  );

                  final interactiveViewer = GestureDetector(
                    onDoubleTap: _toggleToolbar,
                    child: InteractiveViewer(
                      transformationController: _transformationController,
                      boundaryMargin: const EdgeInsets.all(2000),
                      minScale: 0.01,
                      maxScale: 5.0,
                      panEnabled: false,
                      scaleEnabled: true,
                      constrained: false,
                      child: canvasWidget,
                    ),
                  );

                  if (widget.heroTag != null) {
                    return Hero(
                      tag: widget.heroTag!,
                      flightShuttleBuilder:
                          (
                            flightContext,
                            animation,
                            flightDirection,
                            fromHeroContext,
                            toHeroContext,
                          ) {
                            // Use the preview image during flight for smooth transition
                            if (_sketchData.previewImage != null) {
                              return AnimatedBuilder(
                                animation: animation,
                                builder: (context, child) {
                                  return ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      8 * (1 - animation.value),
                                    ),
                                    child: UniversalImage(
                                      path: _sketchData.previewImage!,
                                      fit: BoxFit.contain,
                                    ),
                                  );
                                },
                              );
                            }
                            return toHeroContext.widget;
                          },
                      child: interactiveViewer,
                    );
                  }
                  return interactiveViewer;
                },
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: widget.note.readOnly
                  ? const SizedBox.shrink()
                  : SlideTransition(
                      position: _toolbarSlideAnimation,
                      child: FadeTransition(
                        opacity: _toolbarFadeAnimation,
                        child: AdaptiveToolbar(
                          parentColor: _backgroundColor,
                          child: GestureDetector(
                            onHorizontalDragEnd: _showPagination
                                ? (details) {
                                    // Swipe left to go to next sketch
                                    if (details.primaryVelocity != null &&
                                        details.primaryVelocity! < -200) {
                                      _navigateToSketch(
                                        _currentSketchIndex + 1,
                                      );
                                    }
                                    // Swipe right to go to previous sketch
                                    else if (details.primaryVelocity != null &&
                                        details.primaryVelocity! > 200) {
                                      _navigateToSketch(
                                        _currentSketchIndex - 1,
                                      );
                                    }
                                  }
                                : null,
                            child: CustomScrollView(
                              scrollDirection: Axis.horizontal,
                              shrinkWrap: true,
                              slivers: [
                                // Previous sketch button
                                if (_showPagination)
                                  IconButton(
                                    icon: const Icon(Icons.chevron_left),
                                    onPressed: _currentSketchIndex > 0
                                        ? () => _navigateToSketch(
                                            _currentSketchIndex - 1,
                                          )
                                        : null,
                                    tooltip: 'Previous sketch',
                                  ),
                                // Page indicator
                                if (_showPagination)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: Center(
                                      child: Text(
                                        '${_currentSketchIndex + 1}/$_totalSketches',
                                        style: TextStyle(
                                          color: _foregroundColor.withValues(
                                            alpha: 0.7,
                                          ),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                // Next sketch button
                                if (_showPagination)
                                  IconButton(
                                    icon: const Icon(Icons.chevron_right),
                                    onPressed:
                                        _currentSketchIndex < _totalSketches - 1
                                        ? () => _navigateToSketch(
                                            _currentSketchIndex + 1,
                                          )
                                        : null,
                                    tooltip: 'Next sketch',
                                  ),
                                // Divider between pagination and tools
                                if (_showPagination)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    child: VerticalDivider(
                                      width: 16,
                                      thickness: 1,
                                      color: _foregroundColor.withValues(
                                        alpha: 0.2,
                                      ),
                                    ),
                                  ),
                                IconButton(
                                  icon: const Icon(Icons.undo),
                                  onPressed: _undoCount == 0
                                      ? null
                                      : () {
                                          setState(() {
                                            --_undoCount;
                                            _redoStack.add(
                                              _strokes.removeLast(),
                                            );
                                            _isDirty = true;
                                          });
                                        },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.redo),
                                  onPressed: _redoStack.isEmpty
                                      ? null
                                      : () {
                                          setState(() {
                                            ++_undoCount;
                                            _strokes.add(
                                              _redoStack.removeLast(),
                                            );
                                            _isDirty = true;
                                          });
                                        },
                                ),
                                _buildToolButtonButton(SketchTool.pen),
                                _buildToolButtonButton(SketchTool.eraser),
                              ].map((el) => SliverToBoxAdapter(child: el)).toList(),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolButtonButton(SketchTool tool) {
    final isSelected = _selectedTool == tool;
    final toolType = tool == SketchTool.eraser
        ? SketchToolType.eraser
        : SketchToolType.pen;

    final iconButton = IconButton(
      mouseCursor: SystemMouseCursors.click,
      isSelected: isSelected,
      icon: Icon(tool == SketchTool.eraser ? CustomIcons.eraser : Icons.edit),
      onPressed: isSelected
          ? null // Popup is handled by SketchToolPopup
          : () {
              setState(() {
                _selectedTool = tool;
              });
            },
    );

    // When selected, wrap in popup for tool options
    if (isSelected) {
      return SketchToolPopup(
        toolType: toolType,
        selectedColor: _selectedColor,
        penSize: _penSize,
        eraserSize: _eraserSize,
        onColorChanged: (color) {
          setState(() {
            _selectedColor = color;
          });
        },
        onPenSizeChanged: (size) {
          setState(() {
            _penSize = size;
          });
        },
        onEraserSizeChanged: (size) {
          setState(() {
            _eraserSize = size;
          });
        },
        child: iconButton,
      );
    }

    return iconButton;
  }

  Future<void> _loadBackgroundImage() async {
    final bgImage = _sketchData.backgroundImage!;

    // Check cache first
    if (_backgroundImageCache.containsKey(bgImage)) {
      final cachedImage = _backgroundImageCache[bgImage]!;
      setState(() {
        _loadedBackgroundImage = cachedImage;
        if (_isImageBasedSketch) {
          _canvasSize = Size(
            cachedImage.width.toDouble(),
            cachedImage.height.toDouble(),
          );
          _hasFitted = false;
        }
      });
      return;
    }

    final fs = await fileSystem();

    if (!await fs.exists(bgImage)) {
      throw "$bgImage not found";
    }

    final data = await fs.readBytes(bgImage);
    final codec = await ui.instantiateImageCodec(data);
    final frame = await codec.getNextFrame();

    // Add to cache, evict oldest if too large
    if (_backgroundImageCache.length >= _maxImageCacheSize) {
      _backgroundImageCache.remove(_backgroundImageCache.keys.first);
    }
    _backgroundImageCache[bgImage] = frame.image;

    setState(() {
      _loadedBackgroundImage = frame.image;
      // When we have a background image, use its dimensions for the canvas
      if (_isImageBasedSketch) {
        _canvasSize = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
        _hasFitted = false; // Re-fit to screen with new canvas size
      }
    });
  }

  void _fitToScreen(double viewportWidth, double viewportHeight) {
    final double scaleX = viewportWidth / _canvasSize.width;
    final double scaleY = viewportHeight / _canvasSize.height;
    final double scale = min(scaleX, scaleY) * 0.95;

    final double offsetX = (viewportWidth - _canvasSize.width * scale) / 2;
    final double offsetY = (viewportHeight - _canvasSize.height * scale) / 2;

    _transformationController.value = Matrix4.identity()
      ..setEntry(0, 3, offsetX)
      ..setEntry(1, 3, offsetY)
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(2, 2, scale);
  }

  void _startStroke(double x, double y, double? pressure) {
    setState(() {
      _currentStroke = SketchStroke(
        points:
            '${x.toStringAsFixed(2)},${y.toStringAsFixed(2)},${(pressure ?? 0.5).toStringAsFixed(2)}',
        color: _selectedColor,
        size: _selectedTool == SketchTool.eraser ? _eraserSize : _penSize,
        tool: _selectedTool,
      );
    });
  }

  void _updateStroke(double x, double y, double? pressure) {
    setState(() {
      if (_currentStroke != null) {
        _currentStroke!.points +=
            ';${x.toStringAsFixed(2)},${y.toStringAsFixed(2)},${(pressure ?? 0.5).toStringAsFixed(2)}';
      }
    });
  }

  void _endStroke() {
    setState(() {
      if (_currentStroke != null) {
        ++_undoCount;
        _redoStack.clear();
        _strokes.add(_currentStroke!);
        _currentStroke = null;
        _isDirty = true;
      }
    });

    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 3), _save);
  }

  /// Save sketch in background without blocking UI.
  /// Captures all necessary state upfront so save completes even after widget disposes.
  void _saveInBackground() {
    _autoSaveTimer?.cancel();

    // Skip save if nothing changed
    if (!_isDirty && !_isDeleted) {
      return;
    }

    // Capture all state needed for saving
    final strokes = List<SketchStroke>.from(_strokes);
    final isDeleted = _isDeleted;
    final sketchData = _sketchData;
    final note = widget.note;
    final canvasSize = _canvasSize;
    final paperColor = _paperColor;
    final isImageBasedSketch = _isImageBasedSketch;
    final loadedBackgroundImage = _loadedBackgroundImage;
    final sourceAttachment = widget.sourceAttachment;

    // Fire and forget - save happens in background
    _saveSketchAsync(
      strokes: strokes,
      isDeleted: isDeleted,
      sketchData: sketchData,
      note: note,
      canvasSize: canvasSize,
      paperColor: paperColor,
      isImageBasedSketch: isImageBasedSketch,
      loadedBackgroundImage: loadedBackgroundImage,
      sourceAttachment: sourceAttachment,
    );
  }

  /// Maximum preview image size in bytes (500KB)
  static const int _maxPreviewSize = 500 * 1024;

  /// Compresses a sketch preview image.
  /// Note: FlutterImageCompress uses platform channels which don't work in isolates,
  /// so this runs on main thread but is async to allow UI to breathe.
  static Future<Uint8List> _compressSketchPreview(Uint8List pngBytes) async {
    // First try: quality 80, original size
    var compressed = await FlutterImageCompress.compressWithList(
      pngBytes,
      quality: 80,
      format: CompressFormat.jpeg,
    );

    if (compressed.length <= _maxPreviewSize) {
      return compressed;
    }

    // Second try: quality 60, reduced size
    compressed = await FlutterImageCompress.compressWithList(
      pngBytes,
      quality: 60,
      minWidth: 1200,
      minHeight: 1200,
      format: CompressFormat.jpeg,
    );

    if (compressed.length <= _maxPreviewSize) {
      return compressed;
    }

    // Final try: quality 50, smaller size
    return FlutterImageCompress.compressWithList(
      pngBytes,
      quality: 50,
      minWidth: 800,
      minHeight: 800,
      format: CompressFormat.jpeg,
    );
  }

  static Future<void> _saveSketchAsync({
    required List<SketchStroke> strokes,
    required bool isDeleted,
    required SketchData sketchData,
    required Note note,
    required Size canvasSize,
    required Color paperColor,
    required bool isImageBasedSketch,
    required ui.Image? loadedBackgroundImage,
    required NoteAttachment? sourceAttachment,
  }) async {
    if (isDeleted) {
      note.removeSketch(sketchData);
      return;
    }

    try {
      if (strokes.isEmpty) {
        if (note.hasSketch(sketchData)) {
          note.removeSketch(sketchData);
        }
        return;
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      // Draw background
      if (isImageBasedSketch) {
        canvas.drawColor(Colors.transparent, BlendMode.clear);
      } else {
        canvas.drawColor(paperColor, BlendMode.src);
      }

      if (loadedBackgroundImage != null) {
        paintImage(
          canvas: canvas,
          rect: Offset.zero & canvasSize,
          image: loadedBackgroundImage,
          fit: isImageBasedSketch ? BoxFit.fill : BoxFit.contain,
        );
      }

      // Draw page pattern
      if (!isImageBasedSketch && sketchData.pagePattern != PagePattern.blank) {
        final patternPainter = PagePatternPainter(
          pattern: sketchData.pagePattern,
          lineColor: isDark(paperColor)
              ? Colors.white.withValues(alpha: 0.25)
              : Colors.black.withValues(alpha: 0.18),
        );
        patternPainter.paint(canvas, canvasSize);
      }

      // Draw strokes
      final painter = SketchPainter(strokes: strokes);
      painter.paint(canvas, canvasSize);

      final picture = recorder.endRecording();
      final img = await picture.toImage(
        canvasSize.width.toInt(),
        canvasSize.height.toInt(),
      );
      final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);

      if (pngBytes == null) {
        throw 'Failed to encode sketch image';
      }

      // Compress the preview image to be under 500KB
      final compressedBytes = await _compressSketchPreview(
        pngBytes.buffer.asUint8List(),
      );

      final fs = await fileSystem();
      String previewPath = path.join(
        await fs.documentDir,
        'sketches',
        '${DateTime.now().millisecondsSinceEpoch}_preview.jpg',
      );
      // Fire and forget - don't await file write to prevent OPFS blocking UI
      writeEncryptedBytes(previewPath, compressedBytes).catchError((e) {
        AppLogger.error('Error writing preview', e);
      });

      sketchData.strokes = strokes;
      sketchData.backgroundColor = paperColor;
      sketchData.previewImage = previewPath;
      sketchData.aspectRatio = canvasSize.width / canvasSize.height;

      // If this was an image attachment, convert it to a sketch
      if (isImageBasedSketch && sourceAttachment != null) {
        sourceAttachment.type = AttachmentType.sketch;
        sourceAttachment.sketch = sketchData;
        sourceAttachment.image = null;
        note.save();
      } else if (!note.hasSketch(sketchData)) {
        note.addSketch(sketchData);
      } else {
        note.save();
      }
    } catch (e) {
      AppLogger.error('Error saving sketch in background', e);
    }
  }

  Future<void> _save() async {
    // Don't save while user is actively drawing - reschedule for later
    if (_currentStroke != null) {
      _autoSaveTimer?.cancel();
      _autoSaveTimer = Timer(const Duration(seconds: 3), _save);
      return;
    }

    // Don't save if the sketch was deleted
    if (_isDeleted) {
      widget.note.removeSketch(_sketchData);
      return;
    }

    try {
      if (_strokes.isEmpty) {
        if (widget.note.hasSketch(_sketchData)) {
          widget.note.removeSketch(_sketchData);
        }
        return;
      }

      _autoSaveTimer?.cancel();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final bodySize = _canvasSize;

      // Draw background
      if (_isImageBasedSketch) {
        // For image-based sketch, use transparent background
        canvas.drawColor(Colors.transparent, BlendMode.clear);
      } else {
        canvas.drawColor(_paperColor, BlendMode.src);
      }

      if (_loadedBackgroundImage != null) {
        paintImage(
          canvas: canvas,
          rect: Offset.zero & bodySize,
          image: _loadedBackgroundImage!,
          fit: _isImageBasedSketch ? BoxFit.fill : BoxFit.contain,
        );
      }

      // Draw page pattern
      if (!_isImageBasedSketch &&
          _sketchData.pagePattern != PagePattern.blank) {
        final patternPainter = PagePatternPainter(
          pattern: _sketchData.pagePattern,
          lineColor: isDark(_paperColor)
              ? Colors.white.withValues(alpha: 0.25)
              : Colors.black.withValues(alpha: 0.18),
        );
        patternPainter.paint(canvas, bodySize);
      }

      // Draw strokes
      final painter = SketchPainter(strokes: _strokes);
      painter.paint(canvas, bodySize);

      final picture = recorder.endRecording();
      final img = await picture.toImage(
        bodySize.width.toInt(),
        bodySize.height.toInt(),
      );
      final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);

      if (pngBytes == null) {
        throw 'Failed to encode sketch image';
      }

      // Compress the preview image to be under 500KB
      final compressedBytes = await _compressSketchPreview(
        pngBytes.buffer.asUint8List(),
      );

      final fs = await fileSystem();
      String previewPath = path.join(
        await fs.documentDir,
        'sketches',
        '${DateTime.now().millisecondsSinceEpoch}_preview.jpg',
      );
      // Fire and forget - don't await file write to prevent OPFS blocking UI
      writeEncryptedBytes(previewPath, compressedBytes).catchError((e) {
        AppLogger.error('Error writing preview', e);
      });

      _sketchData.strokes = _strokes;
      _sketchData.backgroundColor = _paperColor;
      _sketchData.previewImage = previewPath;
      _sketchData.aspectRatio = bodySize.width / bodySize.height;

      // If this was an image attachment, convert it to a sketch
      if (_isImageBasedSketch && widget.sourceAttachment != null) {
        // Update the source attachment to become a sketch
        widget.sourceAttachment!.type = AttachmentType.sketch;
        widget.sourceAttachment!.sketch = _sketchData;
        widget.sourceAttachment!.image = null;
        widget.note.save();
        // Add to local sketches if not already there
        if (!_localSketches.contains(_sketchData)) {
          _localSketches.add(_sketchData);
        }
        _pendingNewSketch = null;
      } else if (!widget.note.hasSketch(_sketchData)) {
        widget.note.addSketch(_sketchData);
        // Add to local sketches and update index
        if (!_localSketches.contains(_sketchData)) {
          _localSketches.add(_sketchData);
          _currentSketchIndex = _localSketches.indexOf(_sketchData);
        }
        _pendingNewSketch = null;
      } else {
        widget.note.save();
      }
      _isDirty = false;
    } catch (e) {
      snackbar("Error saving sketch $e", Colors.red);
      AppLogger.error('Error saving sketch', e);
    }
  }

  void _pickColor(bool isBackground, {void Function(Color)? onUpdate}) async {
    final color = await colorPicker(
      context,
      isBackground ? 'Pick Paper Color' : 'Pick Pen Color',
      isBackground ? _paperColor : _selectedColor,
    );

    if (color != null) {
      setState(() {
        if (isBackground) {
          _paperColor = color;
          _isDirty = true;
        } else {
          _selectedColor = color;
          _selectedTool = SketchTool.pen;
        }
      });

      if (onUpdate != null) {
        onUpdate(color);
      }
    }
  }

  Future<void> _saveToGallery() async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final bodySize = _canvasSize;

      // Draw background - same logic as preview save
      if (_isImageBasedSketch) {
        // For image-based sketch, use transparent background
        canvas.drawColor(Colors.transparent, BlendMode.clear);
      } else {
        canvas.drawColor(_paperColor, BlendMode.src);
      }

      if (_loadedBackgroundImage != null) {
        paintImage(
          canvas: canvas,
          rect: Offset.zero & bodySize,
          image: _loadedBackgroundImage!,
          fit: _isImageBasedSketch ? BoxFit.fill : BoxFit.contain,
        );
      }

      // Draw page pattern
      if (!_isImageBasedSketch &&
          _sketchData.pagePattern != PagePattern.blank) {
        final patternPainter = PagePatternPainter(
          pattern: _sketchData.pagePattern,
          lineColor: isDark(_paperColor)
              ? Colors.white.withValues(alpha: 0.25)
              : Colors.black.withValues(alpha: 0.18),
        );
        patternPainter.paint(canvas, bodySize);
      }

      // Draw strokes
      final painter = SketchPainter(strokes: _strokes);
      painter.paint(canvas, bodySize);

      final picture = recorder.endRecording();
      final img = await picture.toImage(
        bodySize.width.toInt(),
        bodySize.height.toInt(),
      );
      final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);

      if (pngBytes != null) {
        final fs = await fileSystem();
        final index = _localSketches.indexOf(_sketchData);
        final fileName = 'sketch_${widget.note.id}_$index.png';

        final success = await fs.saveToGallery(
          pngBytes.buffer.asUint8List(),
          fileName,
        );

        if (!mounted) return;
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(kIsWeb ? 'Sketch downloaded' : 'Saved to Gallery'),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to save sketch')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving sketch: $e')));
      }
    }
  }
}

class SketchPainter extends CustomPainter {
  final List<SketchStroke> strokes;

  /// Cache for parsed points and computed stroke outlines
  /// Key: stroke.points hashCode, Value: computed outline points
  static final Map<int, List<Offset>> _strokeCache = {};
  static const int _maxCacheSize = 500;

  SketchPainter({required this.strokes});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    for (final stroke in strokes) {
      // Use cache key based on points string and size
      final cacheKey = Object.hash(stroke.points, stroke.size);

      List<Offset> outlinePoints;
      if (_strokeCache.containsKey(cacheKey)) {
        outlinePoints = _strokeCache[cacheKey]!;
      } else {
        outlinePoints = getStroke(
          SketchStroke.parsePoints(stroke.points),
          options: StrokeOptions(
            size: stroke.size,
            thinning: 0.5,
            smoothing: 0.5,
            streamline: 0.5,
            isComplete: true,
          ),
        );
        // Add to cache, evict oldest if too large
        if (_strokeCache.length >= _maxCacheSize) {
          _strokeCache.remove(_strokeCache.keys.first);
        }
        _strokeCache[cacheKey] = outlinePoints;
      }

      final path = Path();
      if (outlinePoints.isEmpty) continue;

      path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);
      for (int i = 1; i < outlinePoints.length; i++) {
        path.lineTo(outlinePoints[i].dx, outlinePoints[i].dy);
      }
      path.close();

      final paint = Paint()
        ..color = stroke.tool == SketchTool.eraser
            ? Colors.white
            : stroke
                  .color // Eraser logic needs improvement for non-white bg
        ..style = PaintingStyle.fill
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      if (stroke.tool == SketchTool.eraser) {
        paint.blendMode = BlendMode.clear;
      }

      // If using BlendMode.clear, we need to use a saveLayer to avoid clearing the background widget
      // But here we are painting on top of the scaffold background.
      // If we want true eraser, we should probably use saveLayer for the whole drawing.

      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SketchPainter oldDelegate) {
    // Only repaint if strokes have changed
    if (strokes.length != oldDelegate.strokes.length) return true;
    for (int i = 0; i < strokes.length; i++) {
      if (strokes[i].points != oldDelegate.strokes[i].points ||
          strokes[i].color != oldDelegate.strokes[i].color ||
          strokes[i].size != oldDelegate.strokes[i].size ||
          strokes[i].tool != oldDelegate.strokes[i].tool) {
        return true;
      }
    }
    return false;
  }
}

/// Captures the state needed for a debounced save operation
class _PendingSaveState {
  final SketchData sketchData;
  final List<SketchStroke> strokes;
  final Color paperColor;
  final Size canvasSize;
  final bool isImageBasedSketch;
  final ui.Image? loadedBackgroundImage;
  final Note note;
  final NoteAttachment? sourceAttachment;
  final List<SketchData> localSketches;
  final void Function(int)? onIndexUpdate;

  _PendingSaveState({
    required this.sketchData,
    required this.strokes,
    required this.paperColor,
    required this.canvasSize,
    required this.isImageBasedSketch,
    required this.loadedBackgroundImage,
    required this.note,
    required this.sourceAttachment,
    required this.localSketches,
    this.onIndexUpdate,
  });
}
