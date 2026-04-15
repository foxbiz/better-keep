import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:better_keep/components/adaptive_popup_menu.dart';
import 'package:better_keep/components/page_pattern_painter.dart';
import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/components/sketch_tool_popup.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/ui/custom_icons.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
import 'package:better_keep/utils/image_compressor.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as path;
import 'package:better_keep/components/adaptive_toolbar.dart';
import 'package:better_keep/dialogs/delete_dialog.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/dialogs/color_picker.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:uuid/uuid.dart';

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

  /// Release all cached background images to free native graphics memory.
  /// We only clear the map reference — we cannot dispose the ui.Image objects
  /// because a SketchPage may still be painting with them on the current frame.
  static void clearBackgroundImageCache() {
    _SketchPageState._backgroundImageCache.clear();
  }

  @override
  State<SketchPage> createState() => _SketchPageState();
}

class _SketchPageState extends State<SketchPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final TransformationController _transformationController =
      TransformationController();

  /// Selected pen color - initialized from AppState in initState
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

  // Appbar animation
  late AnimationController _appbarAnimationController;
  late Animation<Offset> _appbarSlideAnimation;
  late Animation<double> _appbarFadeAnimation;
  bool _isAppbarVisible = true;

  // Double tap detection
  DateTime? _lastTapTime;
  static const _doubleTapThreshold = Duration(milliseconds: 200);
  Timer? _pendingDotTimer;
  Offset? _pendingDotPosition;
  double? _pendingDotPressure;

  bool _hasFitted = false;
  SketchTool _selectedTool = SketchTool.pen;

  /// Whether move/pan mode is active (not a drawing tool)
  bool _isMoveMode = false;

  /// The currently selected drawing tool mode (pen, pencil, brush, highlighter)
  /// Initialized from AppState in initState for persistence
  late SketchTool _selectedPenMode;

  int _activePointerCount = 0;
  bool _isMultiTouch = false;

  /// Track if we've started drawing (passed movement threshold)
  bool _hasStartedDrawing = false;

  /// Initial touch position for gesture detection
  Offset? _initialTouchPosition;

  /// Minimum distance to move before starting a stroke (helps distinguish from pinch)
  static const double _strokeStartThreshold = 3.0;

  Timer? _autoSaveTimer;
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

  @override
  void initState() {
    super.initState();

    // Load persisted sketch preferences from AppState
    _selectedPenMode = AppState.sketchTool;
    _selectedTool = _selectedPenMode;
    _selectedColor = AppState.sketchPenColor;

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

    // Initialize appbar animation controller
    _appbarAnimationController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _appbarSlideAnimation =
        Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(
          CurvedAnimation(
            parent: _appbarAnimationController,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
        );
    _appbarFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _appbarAnimationController,
        curve: Curves.easeOut,
      ),
    );
    // Start with appbar visible
    _appbarAnimationController.forward();

    // Initialize local sketches from note - this won't change when note updates
    _localSketches = List<SketchData>.from(widget.note.sketches);

    _sketchData = widget.sketch;
    // Initialize sketch index from parameter or find it in the list
    // For new sketches (not yet in the list), indexOf returns -1, so we default to 0
    final existingIndex = _localSketches.indexOf(_sketchData);
    _currentSketchIndex =
        widget.initialIndex ?? (existingIndex >= 0 ? existingIndex : 0);

    // If this is a new sketch not in the list, mark it as pending
    if (existingIndex < 0) {
      _pendingNewSketch = _sketchData;
      _currentSketchIndex = _localSketches.length;
    }

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
    // Keep persisted color if it contrasts with paper, otherwise use contrast color
    if (!_isImageBasedSketch && isDark(_paperColor) == isDark(_selectedColor)) {
      _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;
    }

    // Load strokes from file if strokes are empty but file exists
    // This happens after app reload when strokes are stored in file
    if (_strokes.isEmpty && _sketchData.hasStrokesFile) {
      // Load strokes and then background image sequentially
      _loadStrokesFromFile().then((_) {
        if (mounted && _sketchData.backgroundImage != null) {
          _loadBackgroundImage();
        }
      });
    } else if (_sketchData.backgroundImage != null) {
      _loadBackgroundImage();
    }
    WidgetsBinding.instance.addObserver(this);
  }

  /// Load strokes from the strokes file
  Future<void> _loadStrokesFromFile() async {
    try {
      final bytes = await readEncryptedBytes(_sketchData.strokesFilePath!);
      final strokesJson = json.decode(utf8.decode(bytes));
      _sketchData.loadFromStrokesFileJson(strokesJson as Map<String, dynamic>);
      if (mounted) {
        setState(() {
          _strokes = List<SketchStroke>.from(_sketchData.strokes);
          _paperColor = _isImageBasedSketch
              ? Colors.transparent
              : _sketchData.backgroundColor;
          _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;
        });
      }
    } catch (e) {
      AppLogger.error('Error loading strokes from file', e);
    }
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
    // Restore system UI when leaving the page
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );
    _toolbarAnimationController.dispose();
    _appbarAnimationController.dispose();
    _transformationController.dispose();
    _pagesPopupController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _autoSaveTimer?.cancel();
    _pendingDotTimer?.cancel();
    // Flush any pending debounced save immediately
    _flushPendingSave();
    super.dispose();
  }

  /// Toggle toolbar and appbar visibility with animation
  void _toggleToolbar() {
    // Cancel any pending dot placement on double tap
    _pendingDotTimer?.cancel();
    _pendingDotTimer = null;
    _pendingDotPosition = null;
    _pendingDotPressure = null;
    _lastTapTime = null;

    setState(() {
      _isToolbarVisible = !_isToolbarVisible;
      _isAppbarVisible = !_isAppbarVisible;
    });
    if (_isToolbarVisible) {
      _toolbarAnimationController.forward();
      _appbarAnimationController.forward();
      // Show system UI (status bar)
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.edgeToEdge,
        overlays: SystemUiOverlay.values,
      );
    } else {
      _toolbarAnimationController.reverse();
      _appbarAnimationController.reverse();
      // Hide system UI (status bar) for fullscreen
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
            snackbar(context.l10n.errorSavingSketch(e.toString()), Colors.red);
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
      // Reuse existing preview path or create new one (only if valid local path)
      final existingPreviewPath = state.sketchData.previewImage;
      String previewPath;
      if (existingPreviewPath != null && existingPreviewPath.isNotEmpty) {
        previewPath = existingPreviewPath;
      } else {
        previewPath = path.join(await fs.documentDir, '${Uuid().v4()}.jpg');
      }
      // Update cache immediately with new bytes so UI shows updated preview
      // This avoids race condition where UI rebuilds before file write completes
      UniversalImageCache.instance.put(
        previewPath,
        previewPath,
        compressedBytes,
      );

      // Fire and forget - don't await file write to prevent OPFS blocking UI
      writeEncryptedBytes(previewPath, compressedBytes).catchError((e) {
        AppLogger.error('Error writing preview', e);
      });

      // Generate tiny thumbnail for locked note preview (under 1KB)
      final thumbnail = await ThumbnailGenerator.generateFromBytes(
        compressedBytes,
      );

      state.sketchData.strokes = state.strokes;
      state.sketchData.backgroundColor = state.paperColor;
      state.sketchData.previewImage = previewPath;
      state.sketchData.aspectRatio = bodySize.width / bodySize.height;
      state.sketchData.blurredThumbnail = thumbnail;

      // Reuse existing strokes file path or create new one (only if valid local path)
      final existingStrokesPath = state.sketchData.strokesFilePath;
      String strokesFilePath;
      if (existingStrokesPath != null && existingStrokesPath.isNotEmpty) {
        strokesFilePath = existingStrokesPath;
      } else {
        strokesFilePath = path.join(
          await fs.documentDir,
          '${Uuid().v4()}.json',
        );
      }
      final strokesJson = json.encode(state.sketchData.toStrokesFileJson());
      // Set strokesFilePath before write so toJson() assertion passes
      state.sketchData.strokesFilePath = strokesFilePath;
      // Await strokes file write - must complete before note save triggers sync
      try {
        await writeEncryptedBytes(
          strokesFilePath,
          Uint8List.fromList(utf8.encode(strokesJson)),
        );
      } catch (e) {
        AppLogger.error('Error writing strokes file', e);
      }

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

    // Keep current paper color to prevent flash while loading
    final previousPaperColor = _paperColor;

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

      // Keep previous paper color if strokes need to be loaded from file
      // (the actual color will be set when strokes file is loaded)
      if (_strokes.isEmpty && _sketchData.hasStrokesFile) {
        _paperColor = previousPaperColor;
      } else {
        _paperColor = _isImageBasedSketch
            ? Colors.transparent
            : _sketchData.backgroundColor;
      }
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

    // Load strokes from file if needed (strokes might be empty if stored in file)
    if (_strokes.isEmpty && _sketchData.hasStrokesFile) {
      _loadStrokesFromFile().then((_) {
        // Load background image after strokes are loaded
        if (mounted &&
            _sketchData.backgroundImage != null &&
            cachedBgImage == null) {
          _loadBackgroundImage();
        }
      });
    } else if (_sketchData.backgroundImage != null && cachedBgImage == null) {
      // Load background image if present and not cached
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
        if (mounted) {
          Navigator.pop(context);
        }
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
      if (mounted) {
        Navigator.pop(context);
      }
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
    // Capture current sketch settings before saving
    final currentBgColor = _sketchData.backgroundColor;
    final currentPagePattern = _sketchData.pagePattern;

    // Save current sketch first if it has strokes
    if (_strokes.isNotEmpty) {
      await _save();
      // Clear pending since we just saved
      _pendingNewSketch = null;
    }

    if (!mounted) {
      return;
    }

    // Create new sketch data with same settings as current sketch
    final newSketch = SketchData(
      backgroundColor: currentBgColor,
      pagePattern: currentPagePattern,
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
          thinning: 0.4,
          smoothing: 0.85, // High smoothing for buttery smooth strokes
          streamline: 0.75, // Better streamline for natural flow
          isComplete: true,
        ),
      );

      if (outlinePoints.isEmpty) continue;

      // Use quadratic Bezier curves for silky smooth edges
      final path = Path();
      path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

      for (int i = 1; i < outlinePoints.length - 1; i++) {
        final p0 = outlinePoints[i];
        final p1 = outlinePoints[i + 1];
        final midX = (p0.dx + p1.dx) / 2;
        final midY = (p0.dy + p1.dy) / 2;
        path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
      }

      if (outlinePoints.length > 1) {
        final last = outlinePoints.last;
        path.lineTo(last.dx, last.dy);
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
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
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
        body: Stack(
          children: [
            // Canvas - fills the entire screen including behind appbar
            Positioned.fill(
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
                              // Only show cursor indicator for actual mouse, not stylus hover
                              if (event.kind == ui.PointerDeviceKind.mouse) {
                                setState(() {
                                  _cursorPosition = event.localPosition;
                                  _isMouseInput = true;
                                });
                              }
                            },
                            onExit: (event) {
                              setState(() {
                                _cursorPosition = null;
                              });
                            },
                            child: Listener(
                              onPointerDown: (details) {
                                if (widget.note.readOnly || _isMoveMode) return;
                                setState(() {
                                  _isMouseInput =
                                      details.kind ==
                                      ui.PointerDeviceKind.mouse;
                                  _cursorPosition = details.localPosition;
                                  _activePointerCount++;
                                  if (_activePointerCount > 1) {
                                    // Multi-touch detected - cancel any stroke
                                    _isMultiTouch = true;
                                    _currentStroke = null;
                                    _hasStartedDrawing = false;
                                    _initialTouchPosition = null;
                                  } else if (!_isMultiTouch) {
                                    // Store initial position, don't start stroke yet
                                    _initialTouchPosition =
                                        details.localPosition;
                                    _hasStartedDrawing = false;
                                  }
                                });
                              },
                              onPointerMove: (details) {
                                if (widget.note.readOnly || _isMoveMode) return;
                                setState(() {
                                  _cursorPosition = details.localPosition;
                                });
                                if (_isMultiTouch) {
                                  // Multi-touch in progress - ensure stroke is cancelled
                                  if (_currentStroke != null) {
                                    setState(() {
                                      _currentStroke = null;
                                      _hasStartedDrawing = false;
                                    });
                                  }
                                  return;
                                }

                                // Check if we should start drawing
                                if (!_hasStartedDrawing &&
                                    _initialTouchPosition != null) {
                                  final distance =
                                      (details.localPosition -
                                              _initialTouchPosition!)
                                          .distance;
                                  if (distance >= _strokeStartThreshold) {
                                    // Start the stroke from initial position
                                    _hasStartedDrawing = true;
                                    _startStroke(
                                      _initialTouchPosition!.dx,
                                      _initialTouchPosition!.dy,
                                      details.pressure,
                                    );
                                  }
                                }

                                if (_hasStartedDrawing) {
                                  _updateStroke(
                                    details.localPosition.dx,
                                    details.localPosition.dy,
                                    details.pressure,
                                  );
                                }
                              },
                              onPointerUp: (details) {
                                if (widget.note.readOnly || _isMoveMode) return;
                                setState(() {
                                  _activePointerCount--;
                                  if (_activePointerCount == 0) {
                                    _isMultiTouch = false;
                                    if (_hasStartedDrawing) {
                                      _endStroke();
                                    } else if (_initialTouchPosition != null &&
                                        _selectedTool != SketchTool.eraser) {
                                      // Check for double tap - cancel any pending dot
                                      final now = DateTime.now();
                                      final isDoubleTap =
                                          _lastTapTime != null &&
                                          now.difference(_lastTapTime!) <
                                              _doubleTapThreshold;
                                      _lastTapTime = now;

                                      if (isDoubleTap) {
                                        // Cancel pending dot and toggle fullscreen on double tap
                                        _pendingDotTimer?.cancel();
                                        _pendingDotTimer = null;
                                        _pendingDotPosition = null;
                                        _pendingDotPressure = null;
                                        _toggleToolbar();
                                      } else {
                                        // Store dot info and wait for potential second tap
                                        _pendingDotPosition =
                                            _initialTouchPosition;
                                        _pendingDotPressure = details.pressure;
                                        _pendingDotTimer?.cancel();
                                        _pendingDotTimer = Timer(
                                          _doubleTapThreshold,
                                          () {
                                            if (_pendingDotPosition != null) {
                                              _placeDot(
                                                _pendingDotPosition!.dx,
                                                _pendingDotPosition!.dy,
                                                _pendingDotPressure,
                                              );
                                              _pendingDotPosition = null;
                                              _pendingDotPressure = null;
                                              // Reset tap time so next tap is treated as fresh
                                              _lastTapTime = null;
                                            }
                                          },
                                        );
                                      }
                                    }
                                    _hasStartedDrawing = false;
                                    _initialTouchPosition = null;
                                    // Hide cursor for touch input when drawing ends
                                    if (!_isMouseInput) {
                                      _cursorPosition = null;
                                    }
                                  }
                                });
                              },
                              onPointerCancel: (details) {
                                if (widget.note.readOnly || _isMoveMode) return;
                                setState(() {
                                  _activePointerCount--;
                                  if (_activePointerCount == 0) {
                                    _isMultiTouch = false;
                                    // Don't save stroke on cancel
                                    _currentStroke = null;
                                    _hasStartedDrawing = false;
                                    _initialTouchPosition = null;
                                    // Hide cursor for touch input when drawing ends
                                    if (!_isMouseInput) {
                                      _cursorPosition = null;
                                    }
                                  }
                                });
                              },
                              child: CustomPaint(
                                painter: SketchPainter(
                                  strokes: [..._strokes, ?_currentStroke],
                                ),
                                size: Size.infinite,
                              ),
                            ),
                          ),
                        ),
                        // Custom cursor indicator - show for mouse always, for eraser while drawing
                        if (_cursorPosition != null &&
                            (_isMouseInput ||
                                (_currentStroke != null &&
                                    _selectedTool == SketchTool.eraser)))
                          Builder(
                            builder: (context) {
                              final toolSize = AppState.getSketchToolSize(
                                _selectedTool,
                              );
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

                  final interactiveViewer = InteractiveViewer(
                    transformationController: _transformationController,
                    boundaryMargin: const EdgeInsets.all(2000),
                    minScale: 0.01,
                    maxScale: 5.0,
                    panEnabled: _isMoveMode,
                    scaleEnabled: true,
                    constrained: false,
                    child: canvasWidget,
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
            // Floating toolbar at the bottom
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedSwitcher(
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
                            key: Key('sketch_page_toolbar'),
                            parentColor: _backgroundColor,
                            children: [
                              _buildPagesGridButton(),
                              IconButton(
                                icon: const Icon(Icons.undo),
                                onPressed: _undoCount == 0
                                    ? null
                                    : () {
                                        setState(() {
                                          --_undoCount;
                                          _redoStack.add(_strokes.removeLast());
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
                                          _strokes.add(_redoStack.removeLast());
                                          _isDirty = true;
                                        });
                                      },
                              ),
                              _buildMoveToolButton(),
                              _buildToolButtonButton(SketchTool.pen),
                              _buildToolButtonButton(SketchTool.eraser),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
            // Custom pill-shaped titlebar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SlideTransition(
                position: _appbarSlideAnimation,
                child: FadeTransition(
                  opacity: _appbarFadeAnimation,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Left pill: back button
                          _buildTitlebarPill(
                            child: BackButton(color: _foregroundColor),
                          ),
                          // Right pill: action buttons
                          _buildTitlebarPill(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!_isImageBasedSketch)
                                  IconButton(
                                    icon: const Icon(Icons.color_lens),
                                    color: _foregroundColor,
                                    onPressed: () => _pickColor(true),
                                    tooltip: context.l10n.paperColor,
                                  ),
                                if (!_isImageBasedSketch)
                                  PopupMenuButton<PagePattern>(
                                    icon: Icon(
                                      _sketchData.pagePattern.icon,
                                      color: _foregroundColor,
                                    ),
                                    tooltip: context.l10n.pagePattern,
                                    onSelected: (pattern) {
                                      setState(() {
                                        _sketchData.pagePattern = pattern;
                                        _isDirty = true;
                                      });
                                    },
                                    itemBuilder: (context) =>
                                        PagePattern.values.map((pattern) {
                                          final isSelected =
                                              _sketchData.pagePattern ==
                                              pattern;
                                          return PopupMenuItem(
                                            value: pattern,
                                            child: Row(
                                              children: [
                                                Icon(
                                                  pattern.icon,
                                                  color: isSelected
                                                      ? Theme.of(
                                                          context,
                                                        ).colorScheme.primary
                                                      : Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                ),
                                                const SizedBox(width: 12),
                                                Text(
                                                  pattern.displayName,
                                                  style: isSelected
                                                      ? TextStyle(
                                                          color: Theme.of(
                                                            context,
                                                          ).colorScheme.primary,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        )
                                                      : null,
                                                ),
                                              ],
                                            ),
                                          );
                                        }).toList(),
                                  ),
                                PopupMenuButton<String>(
                                  icon: Icon(
                                    Icons.more_vert,
                                    color: _foregroundColor,
                                  ),
                                  tooltip: context.l10n.moreOptions,
                                  onSelected: (value) {
                                    switch (value) {
                                      case 'save':
                                        _saveToGallery();
                                        break;
                                      case 'delete':
                                        _deleteCurrentSketch();
                                        break;
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    if (_strokes.isNotEmpty)
                                      PopupMenuItem(
                                        value: 'save',
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.save_alt,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                            const SizedBox(width: 12),
                                            Text(context.l10n.saveToGallery),
                                          ],
                                        ),
                                      ),
                                    if (_localSketches.contains(_sketchData) ||
                                        _pendingNewSketch == _sketchData)
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.delete,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.error,
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              context.l10n.delete,
                                              style: TextStyle(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.error,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
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

  /// Builds a pill-shaped container with blur background for titlebar buttons
  Widget _buildTitlebarPill({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: _backgroundColor.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(100),
          ),
          child: child,
        ),
      ),
    );
  }

  /// Builds the move/pan tool button
  Widget _buildMoveToolButton() {
    return IconButton(
      mouseCursor: SystemMouseCursors.click,
      isSelected: _isMoveMode,
      icon: const Icon(Icons.open_with_rounded),
      tooltip: context.l10n.move,
      onPressed: () {
        setState(() {
          _isMoveMode = !_isMoveMode;
          // When entering move mode, deselect any active stroke
          if (_isMoveMode) {
            _currentStroke = null;
            _hasStartedDrawing = false;
            _initialTouchPosition = null;
          }
        });
      },
    );
  }

  Widget _buildToolButtonButton(SketchTool tool) {
    // For drawing tools (non-eraser), check if any drawing tool is selected
    final isEraser = tool == SketchTool.eraser;
    final isSelected = _isMoveMode
        ? false // No drawing tool is selected when in move mode
        : isEraser
        ? _selectedTool == SketchTool.eraser
        : _selectedTool.isDrawingTool;
    final toolType = isEraser ? SketchToolType.eraser : SketchToolType.pen;

    // Show the icon of the currently selected pen mode for drawing tools
    final displayIcon = isEraser ? CustomIcons.eraser : _selectedPenMode.icon;

    final iconButton = IconButton(
      mouseCursor: SystemMouseCursors.click,
      isSelected: isSelected,
      icon: Icon(displayIcon),
      onPressed: isSelected
          ? null // Popup is handled by SketchToolPopup
          : () {
              setState(() {
                _isMoveMode = false; // Exit move mode when selecting a tool
                if (isEraser) {
                  _selectedTool = SketchTool.eraser;
                } else {
                  // Switch to the currently selected pen mode
                  _selectedTool = _selectedPenMode;
                }
              });
            },
    );

    // When selected, wrap in popup for tool options
    if (isSelected) {
      // Get the current tool for size (eraser uses eraser, pen uses selectedPenMode)
      final currentTool = isEraser ? SketchTool.eraser : _selectedPenMode;
      return SketchToolPopup(
        toolType: toolType,
        selectedPenMode: _selectedPenMode,
        selectedColor: _selectedColor,
        toolSize: AppState.getSketchToolSize(currentTool),
        onColorChanged: (color) {
          setState(() {
            _selectedColor = color;
          });
          AppState.sketchPenColor = color;
        },
        onSizeChanged: (size) {
          setState(() {
            AppState.setSketchToolSize(currentTool, size);
          });
        },
        onPenModeChanged: (mode) {
          setState(() {
            _selectedPenMode = mode;
            _selectedTool = mode; // Also update current tool
          });
          // Persist the selected tool mode
          AppState.sketchTool = mode;
        },
        child: iconButton,
      );
    }

    return iconButton;
  }

  /// Controller for the pages grid popup
  final AdaptivePopupController _pagesPopupController =
      AdaptivePopupController();

  /// Builds a button that opens a popup grid of all sketch page previews
  Widget _buildPagesGridButton() {
    return AdaptivePopupMenu(
      controller: _pagesPopupController,
      width: 260,
      builder: (context, close) =>
          SizedBox(height: 300, child: _buildPagesGrid(context, close)),
      child: IconButton(
        onPressed: _pagesPopupController.toggle,
        tooltip: context.l10n.viewAllPages,
        icon: Badge(
          label: Text(
            '${_currentSketchIndex + 1}/$_totalSketches',
            style: const TextStyle(fontSize: 10),
          ),
          child: const Icon(Icons.grid_view_rounded),
        ),
      ),
    );
  }

  /// Builds the scrollable grid of page previews
  Widget _buildPagesGrid(BuildContext parentContext, VoidCallback close) {
    // +1 for the "Add new page" button at the end
    final itemCount = _totalSketches + 1;

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.75, // Slightly taller for A4-like pages
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        // Last item is the "Add new page" button
        if (index == _totalSketches) {
          return _buildAddPageButton(context, close);
        }

        final isSelected = index == _currentSketchIndex;
        final isPendingSketch = index >= _localSketches.length;
        final sketch = isPendingSketch
            ? _pendingNewSketch
            : _localSketches[index];

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              close();
              _navigateToSketch(index);
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? Theme.of(parentContext).colorScheme.primary
                      : _foregroundColor.withValues(alpha: 0.2),
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Background color
                    Container(color: sketch?.backgroundColor ?? Colors.white),
                    // Preview image
                    if (sketch?.previewImage != null &&
                        sketch!.previewImage!.isNotEmpty)
                      UniversalImage(
                        path: sketch.previewImage!,
                        fit: BoxFit.cover,
                      ),
                    // Page number badge
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Theme.of(parentContext).colorScheme.primary
                              : Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${index + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Builds the "Add new page" button for the pages grid
  Widget _buildAddPageButton(BuildContext context, VoidCallback close) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          close();
          _createNewSketch();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _foregroundColor.withValues(alpha: 0.2),
              width: 1,
            ),
            color: _foregroundColor.withValues(alpha: 0.05),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_rounded,
                color: _foregroundColor.withValues(alpha: 0.5),
                size: 32,
              ),
              const SizedBox(height: 4),
              Text(
                context.l10n.newLabel,
                style: TextStyle(
                  color: _foregroundColor.withValues(alpha: 0.5),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
      final oldestKey = _backgroundImageCache.keys.first;
      _backgroundImageCache.remove(oldestKey)?.dispose();
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
    final statusBarHeight = MediaQuery.of(context).padding.top;

    final double scaleX = viewportWidth / _canvasSize.width;
    final double scaleY = viewportHeight / _canvasSize.height;
    final double scale = min(scaleX, scaleY) * 0.95;

    final double offsetX = (viewportWidth - _canvasSize.width * scale) / 2;
    double offsetY = (viewportHeight - _canvasSize.height * scale) / 2;

    // If the canvas would overlap with the status bar when centered, push it down
    if (offsetY < statusBarHeight) {
      final availableHeight = viewportHeight - statusBarHeight;
      final adjustedScale =
          min(scaleX, availableHeight / _canvasSize.height) * 0.95;
      offsetY =
          statusBarHeight +
          (availableHeight - _canvasSize.height * adjustedScale) / 2;
    }

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
        // Use full precision for x,y since data is now saved in separate files
        // Pressure is still limited to 3 decimals as that's sufficient
        points: '$x,$y,${(pressure ?? 0.5).toStringAsFixed(3)}',
        color: _selectedColor,
        size: AppState.getSketchToolSize(_selectedTool),
        tool: _selectedTool,
      );
    });
  }

  void _updateStroke(double x, double y, double? pressure) {
    setState(() {
      if (_currentStroke != null) {
        // Use full precision for x,y for buttery smooth Bezier curves
        _currentStroke!.points +=
            ';$x,$y,${(pressure ?? 0.5).toStringAsFixed(3)}';
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

  /// Place a dot at the given position (for quick taps)
  void _placeDot(double x, double y, double? pressure) {
    final p = (pressure ?? 0.5).toStringAsFixed(3);
    // Create a stroke with two points very close together to form a dot
    final dot = SketchStroke(
      points: '$x,$y,$p;${x + 0.1},${y + 0.1},$p',
      color: _selectedColor,
      size: AppState.getSketchToolSize(_selectedTool),
      tool: _selectedTool,
    );
    setState(() {
      ++_undoCount;
      _redoStack.clear();
      _strokes.add(dot);
      _isDirty = true;
    });

    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 3), _save);
  }

  /// Save sketch in background without blocking UI.
  /// Captures all necessary state upfront so save completes even after widget disposes.
  void _saveInBackground() {
    _autoSaveTimer?.cancel();

    // Cancel any pending debounced save to prevent duplicate saves
    _debounceSaveTimer?.cancel();
    _debounceSaveTimer = null;
    _pendingSaveState = null;

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
    var compressed = await ImageCompressor.compressWithList(
      pngBytes,
      quality: 80,
      format: CompressFormat.jpeg,
    );

    if (compressed.length <= _maxPreviewSize) {
      return compressed;
    }

    // Second try: quality 60, reduced size
    compressed = await ImageCompressor.compressWithList(
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
    return ImageCompressor.compressWithList(
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
      // Reuse existing preview path or create new one (only if valid local path)
      final existingPreviewPath = sketchData.previewImage;
      String previewPath;
      if (existingPreviewPath != null && existingPreviewPath.isNotEmpty) {
        previewPath = existingPreviewPath;
      } else {
        previewPath = path.join(await fs.documentDir, '${Uuid().v4()}.jpg');
      }
      // Update cache immediately with new bytes so UI shows updated preview
      // This avoids race condition where UI rebuilds before file write completes
      UniversalImageCache.instance.put(
        previewPath,
        previewPath,
        compressedBytes,
      );

      // Fire and forget - don't await file write to prevent OPFS blocking UI
      writeEncryptedBytes(previewPath, compressedBytes).catchError((e) {
        AppLogger.error('Error writing preview', e);
      });

      // Generate tiny thumbnail for locked note preview (under 1KB)
      final thumbnail = await ThumbnailGenerator.generateFromBytes(
        compressedBytes,
      );

      sketchData.strokes = strokes;
      sketchData.backgroundColor = paperColor;
      sketchData.previewImage = previewPath;
      sketchData.aspectRatio = canvasSize.width / canvasSize.height;
      sketchData.blurredThumbnail = thumbnail;

      // Reuse existing strokes file path or create new one (only if valid local path)
      final existingStrokesPath = sketchData.strokesFilePath;
      String strokesFilePath;
      if (existingStrokesPath != null && existingStrokesPath.isNotEmpty) {
        strokesFilePath = existingStrokesPath;
      } else {
        strokesFilePath = path.join(
          await fs.documentDir,
          '${Uuid().v4()}.json',
        );
      }
      // Set strokesFilePath before write so toJson() assertion passes
      sketchData.strokesFilePath = strokesFilePath;
      final strokesJson = json.encode(sketchData.toStrokesFileJson());
      // Await strokes file write - must complete before note save triggers sync
      try {
        await writeEncryptedBytes(
          strokesFilePath,
          Uint8List.fromList(utf8.encode(strokesJson)),
        );
      } catch (e) {
        AppLogger.error('Error writing strokes file', e);
      }

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
      // Reuse existing preview path or create new one (only if valid local path)
      final existingPreviewPath = _sketchData.previewImage;
      String previewPath;
      if (existingPreviewPath != null && existingPreviewPath.isNotEmpty) {
        previewPath = existingPreviewPath;
      } else {
        previewPath = path.join(await fs.documentDir, '${Uuid().v4()}.jpg');
      }
      // Update cache immediately with new bytes so UI shows updated preview
      // This avoids race condition where UI rebuilds before file write completes
      UniversalImageCache.instance.put(
        previewPath,
        previewPath,
        compressedBytes,
      );

      // Fire and forget - don't await file write to prevent OPFS blocking UI
      writeEncryptedBytes(previewPath, compressedBytes).catchError((e) {
        AppLogger.error('Error writing preview', e);
      });

      // Generate tiny thumbnail for locked note preview (under 1KB)
      final thumbnail = await ThumbnailGenerator.generateFromBytes(
        compressedBytes,
      );

      _sketchData.strokes = _strokes;
      _sketchData.backgroundColor = _paperColor;
      _sketchData.previewImage = previewPath;
      _sketchData.aspectRatio = bodySize.width / bodySize.height;
      _sketchData.blurredThumbnail = thumbnail;

      // Reuse existing strokes file path or create new one (only if valid local path)
      final existingStrokesPath = _sketchData.strokesFilePath;
      String strokesFilePath;
      if (existingStrokesPath != null && existingStrokesPath.isNotEmpty) {
        strokesFilePath = existingStrokesPath;
      } else {
        strokesFilePath = path.join(
          await fs.documentDir,
          '${Uuid().v4()}.json',
        );
      }
      // Set strokesFilePath before write so toJson() assertion passes
      _sketchData.strokesFilePath = strokesFilePath;
      final strokesJson = json.encode(_sketchData.toStrokesFileJson());
      // Await strokes file write - must complete before note save triggers sync
      try {
        await writeEncryptedBytes(
          strokesFilePath,
          Uint8List.fromList(utf8.encode(strokesJson)),
        );
      } catch (e) {
        AppLogger.error('Error writing strokes file', e);
      }

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
      if (mounted) {
        snackbar(context.l10n.errorSavingSketch(e.toString()), Colors.red);
      }
      AppLogger.error('Error saving sketch', e);
    }
  }

  void _pickColor(bool isBackground, {void Function(Color)? onUpdate}) async {
    final color = await colorPicker(
      context,
      isBackground ? context.l10n.pickPaperColor : context.l10n.pickPenColor,
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
              content: Text(
                kIsWeb
                    ? context.l10n.sketchDownloaded
                    : context.l10n.savedToGallery,
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.failedToSaveSketch)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.errorSavingSketch(e.toString()))),
        );
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
      _paintStroke(canvas, stroke);
    }
    canvas.restore();
  }

  void _paintStroke(Canvas canvas, SketchStroke stroke) {
    final points = SketchStroke.parsePoints(stroke.points);
    if (points.isEmpty) return;

    switch (stroke.tool) {
      case SketchTool.eraser:
        _paintEraserStroke(canvas, stroke, points);
        break;
      case SketchTool.pencil:
        _paintPencilStroke(canvas, stroke, points);
        break;
      case SketchTool.brush:
        _paintBrushStroke(canvas, stroke, points);
        break;
      case SketchTool.highlighter:
        _paintHighlighterStroke(canvas, stroke, points);
        break;
      case SketchTool.pen:
        _paintPenStroke(canvas, stroke, points);
        break;
    }
  }

  /// Standard pen stroke - solid, consistent width with buttery smooth Bezier curves
  void _paintPenStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    final cacheKey = Object.hash(stroke.points, stroke.size, stroke.tool);

    List<Offset> outlinePoints;
    if (_strokeCache.containsKey(cacheKey)) {
      outlinePoints = _strokeCache[cacheKey]!;
    } else {
      outlinePoints = getStroke(
        points,
        options: StrokeOptions(
          size: stroke.size,
          thinning: 0.4,
          smoothing: 0.85, // High smoothing for buttery smooth strokes
          streamline: 0.75, // Higher streamline for natural flow
          isComplete: true,
        ),
      );
      if (_strokeCache.length >= _maxCacheSize) {
        _strokeCache.remove(_strokeCache.keys.first);
      }
      _strokeCache[cacheKey] = outlinePoints;
    }

    if (outlinePoints.isEmpty) return;

    // Use quadratic Bezier curves for silky smooth edges
    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    if (outlinePoints.length > 1) {
      final last = outlinePoints.last;
      path.lineTo(last.dx, last.dy);
    }
    path.close();

    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
  }

  /// Pencil stroke - graphite texture with slight opacity and noise
  void _paintPencilStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    final cacheKey = Object.hash(stroke.points, stroke.size, stroke.tool);

    List<Offset> outlinePoints;
    if (_strokeCache.containsKey(cacheKey)) {
      outlinePoints = _strokeCache[cacheKey]!;
    } else {
      outlinePoints = getStroke(
        points,
        options: StrokeOptions(
          size: stroke.size * 0.9, // Slightly thinner than pen
          thinning: 0.55,
          smoothing: 0.7, // Higher smoothing for smoother pencil strokes
          streamline: 0.6, // Better streamline for natural pencil feel
          isComplete: true,
        ),
      );
      if (_strokeCache.length >= _maxCacheSize) {
        _strokeCache.remove(_strokeCache.keys.first);
      }
      _strokeCache[cacheKey] = outlinePoints;
    }

    if (outlinePoints.isEmpty) return;

    // Use quadratic Bezier curves for silky smooth edges
    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    if (outlinePoints.length > 1) {
      final last = outlinePoints.last;
      path.lineTo(last.dx, last.dy);
    }
    path.close();

    // Main pencil stroke with reduced opacity for graphite look
    final paint = Paint()
      ..color = stroke.color.withValues(alpha: 0.75)
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
  }

  /// Brush stroke - variable width based on velocity, tapered ends with buttery smooth Bezier curves
  void _paintBrushStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    final cacheKey = Object.hash(stroke.points, stroke.size, stroke.tool);

    List<Offset> outlinePoints;
    if (_strokeCache.containsKey(cacheKey)) {
      outlinePoints = _strokeCache[cacheKey]!;
    } else {
      outlinePoints = getStroke(
        points,
        options: StrokeOptions(
          size: stroke.size,
          thinning: 0.65, // Refined thinning for natural brush effect
          smoothing: 0.8, // High smoothing for buttery smooth brush strokes
          streamline: 0.75, // Better streamline for fluid brush movement
          start: StrokeEndOptions.start(
            taperEnabled: true,
            customTaper: stroke.size * 2.5,
          ),
          end: StrokeEndOptions.end(
            taperEnabled: true,
            customTaper: stroke.size * 2.5,
          ),
          isComplete: true,
        ),
      );
      if (_strokeCache.length >= _maxCacheSize) {
        _strokeCache.remove(_strokeCache.keys.first);
      }
      _strokeCache[cacheKey] = outlinePoints;
    }

    if (outlinePoints.isEmpty) return;

    // Use quadratic Bezier curves for silky smooth brush strokes
    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    if (outlinePoints.length > 1) {
      final last = outlinePoints.last;
      path.lineTo(last.dx, last.dy);
    }
    path.close();

    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
  }

  /// Highlighter stroke - transparent, wide stroke like a real highlighter
  void _paintHighlighterStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    if (points.length < 2) return;

    // Highlighter uses a wider, flat stroke
    final highlighterSize = stroke.size * 2.5;

    // Draw the main highlight path with transparency
    final paint = Paint()
      ..color = stroke.color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = highlighterSize
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.multiply;

    final path = Path();
    path.moveTo(points[0].x, points[0].y);

    // Use quadratic bezier for smoother curves
    for (int i = 1; i < points.length; i++) {
      final p0 = points[i - 1];
      final p1 = points[i];
      final midX = (p0.x + p1.x) / 2;
      final midY = (p0.y + p1.y) / 2;
      path.quadraticBezierTo(p0.x, p0.y, midX, midY);
    }
    path.lineTo(points.last.x, points.last.y);

    canvas.drawPath(path, paint);
  }

  /// Eraser stroke - clears underlying content with smooth Bezier curves
  void _paintEraserStroke(
    Canvas canvas,
    SketchStroke stroke,
    List<PointVector> points,
  ) {
    final cacheKey = Object.hash(stroke.points, stroke.size, stroke.tool);

    List<Offset> outlinePoints;
    if (_strokeCache.containsKey(cacheKey)) {
      outlinePoints = _strokeCache[cacheKey]!;
    } else {
      outlinePoints = getStroke(
        points,
        options: StrokeOptions(
          size: stroke.size,
          thinning: 0.4,
          smoothing: 0.75, // Smooth erasing for clean edges
          streamline: 0.7,
          isComplete: true,
        ),
      );
      if (_strokeCache.length >= _maxCacheSize) {
        _strokeCache.remove(_strokeCache.keys.first);
      }
      _strokeCache[cacheKey] = outlinePoints;
    }

    if (outlinePoints.isEmpty) return;

    // Use quadratic Bezier curves for smooth eraser edges
    final path = Path();
    path.moveTo(outlinePoints[0].dx, outlinePoints[0].dy);

    for (int i = 1; i < outlinePoints.length - 1; i++) {
      final p0 = outlinePoints[i];
      final p1 = outlinePoints[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      final midY = (p0.dy + p1.dy) / 2;
      path.quadraticBezierTo(p0.dx, p0.dy, midX, midY);
    }

    if (outlinePoints.length > 1) {
      final last = outlinePoints.last;
      path.lineTo(last.dx, last.dy);
    }
    path.close();

    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = BlendMode.clear
      ..isAntiAlias = true;

    canvas.drawPath(path, paint);
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
