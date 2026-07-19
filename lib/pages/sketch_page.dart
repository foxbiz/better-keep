import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:better_keep/components/adaptive_popup_menu.dart';
import 'package:better_keep/components/page_pattern_painter.dart';
import 'package:better_keep/components/sketch_painter.dart';
import 'package:better_keep/components/universal_image.dart';
import 'package:better_keep/components/sketch_tool_popup.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/sketch_preview_repair_service.dart';
import 'package:better_keep/services/sketch_renderer.dart';
import 'package:better_keep/services/sketch_strokes_file_service.dart';
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

const Size kA4Size = kSketchA4Size; // A4 at 96 DPI

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

  @visibleForTesting
  static Future<void> Function(SketchSaveToken token)?
  beforeCapturedSaveOverride;

  @override
  State<SketchPage> createState() => _SketchPageState();
}

/// Keeps file-backed stroke readiness scoped to one sketch activation.
///
/// A generation is stronger than checking [SketchData] identity alone: a user
/// can navigate away from a sketch and return to the same object while its
/// first hydration is still running. The edit revision is a final data-loss
/// guard in case an input path ever bypasses the normal readiness gate.
@visibleForTesting
class SketchPageSourceController {
  int _generation = 0;
  int _strokeEditRevision = 0;
  SketchData? _activeSketch;
  bool _isStrokeSourceReady = false;

  bool get isStrokeSourceReady => _isStrokeSourceReady;

  static bool isImmediatelyReady(SketchData sketch) =>
      !sketch.hasStrokesFile || sketch.hasHydratedStrokeSource;

  SketchSourceActivation activate(SketchData sketch) {
    _activeSketch = sketch;
    _isStrokeSourceReady = isImmediatelyReady(sketch);
    return SketchSourceActivation._(
      sketch: sketch,
      generation: ++_generation,
      strokeEditRevision: _strokeEditRevision,
    );
  }

  bool isCurrent(SketchSourceActivation activation) =>
      activation.generation == _generation &&
      identical(activation.sketch, _activeSketch);

  bool canApplyHydratedSource(SketchSourceActivation activation) =>
      isCurrent(activation) &&
      activation.strokeEditRevision == _strokeEditRevision;

  bool markHydratedSourceReady(SketchSourceActivation activation) {
    if (!canApplyHydratedSource(activation)) return false;
    _isStrokeSourceReady = true;
    return true;
  }

  void recordStrokeEdit() {
    _strokeEditRevision++;
  }
}

@visibleForTesting
class SketchSourceActivation {
  final SketchData sketch;
  final int generation;
  final int strokeEditRevision;

  const SketchSourceActivation._({
    required this.sketch,
    required this.generation,
    required this.strokeEditRevision,
  });
}

/// Invalidates captured saves when a sketch is deleted.
///
/// Identity semantics are intentional: two pages may contain identical drawing
/// data while still having independent save lifecycles.
@visibleForTesting
class SketchSaveGenerationController {
  final Map<SketchData, int> _generations = HashMap<SketchData, int>.identity();
  final Set<SketchData> _tombstones = HashSet<SketchData>.identity();

  SketchSaveToken capture(SketchData sketch) =>
      SketchSaveToken._(sketch: sketch, generation: _generations[sketch] ?? 0);

  void tombstone(SketchData sketch) {
    _generations[sketch] = (_generations[sketch] ?? 0) + 1;
    _tombstones.add(sketch);
  }

  /// Starts a fresh generation after a deletion failure. Previously captured
  /// saves remain invalid, but the user can continue editing and retry.
  void restore(SketchData sketch) {
    _generations[sketch] = (_generations[sketch] ?? 0) + 1;
    _tombstones.remove(sketch);
  }

  bool isDeleted(SketchData sketch) => _tombstones.contains(sketch);

  bool isCurrent(SketchSaveToken token) =>
      !_tombstones.contains(token.sketch) &&
      (_generations[token.sketch] ?? 0) == token.generation;
}

@visibleForTesting
class SketchSaveToken {
  final SketchData sketch;
  final int generation;

  const SketchSaveToken._({required this.sketch, required this.generation});
}

/// Serializes page operations without allowing a failed operation to poison
/// later autosaves, navigation, or deletion.
class _SketchPageOperationQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

enum _SketchSaveResult { saved, unchanged, cancelled }

class _StaleSketchSave implements Exception {
  const _StaleSketchSave();
}

class _SketchPageState extends State<SketchPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final TransformationController _transformationController =
      TransformationController();

  /// Selected pen color - initialized from AppState in initState
  late Color _selectedColor;
  late Color _paperColor;
  late PagePattern _pagePattern;
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
  Future<void> _assetPreparation = Future<void>.value();
  final SketchPageSourceController _sourceController =
      SketchPageSourceController();
  final Map<SketchData, Future<SketchStrokesLoadResult>> _strokeHydrations =
      HashMap<SketchData, Future<SketchStrokesLoadResult>>.identity();
  SketchStroke? _currentStroke;
  List<SketchStroke> _strokes = [];
  ui.Image? _loadedBackgroundImage;
  bool _ownsLoadedBackgroundImage = false;
  bool _backgroundUnavailable = false;
  bool _isRetryingBackground = false;
  late SketchSourceActivation _currentSourceActivation;
  Size _canvasSize = kA4Size;
  bool _isImageBasedSketch = false;
  bool _isDirty = false;
  int _editRevision = 0;
  Offset? _cursorPosition;
  bool _isMouseInput = false;

  /// Image sketches must use the decoded background's intrinsic dimensions
  /// before recording or saving absolute stroke coordinates.
  bool get _isCanvasReady =>
      _sourceController.isStrokeSourceReady &&
      (!_isImageBasedSketch || _loadedBackgroundImage != null);

  bool get _isLegacySketchUnavailable => _sketchData.requiresLegacyMigration;

  /// Cache for loaded background images to avoid re-reading from OPFS
  /// Key: image path, Value: decoded ui.Image
  static final Map<String, ui.Image> _backgroundImageCache = {};
  static const int _maxImageCacheSize = 10;

  final SketchSaveGenerationController _saveGenerations =
      SketchSaveGenerationController();
  final _SketchPageOperationQueue _pageOperations = _SketchPageOperationQueue();
  bool _isClosing = false;
  bool _isDeleting = false;

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
    final activation = _sourceController.activate(_sketchData);
    _currentSourceActivation = activation;
    _paperColor = _isImageBasedSketch
        ? Colors.transparent
        : _sketchData.backgroundColor;
    _pagePattern = _sketchData.pagePattern;
    // Keep persisted color if it contrasts with paper, otherwise use contrast color
    if (!_isImageBasedSketch && isDark(_paperColor) == isDark(_selectedColor)) {
      _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;
    }

    _beginPreparingCurrentSketch(activation);
    WidgetsBinding.instance.addObserver(this);
  }

  void _beginPreparingCurrentSketch(
    SketchSourceActivation activation, {
    bool prepareAssets = true,
  }) {
    // Replace the previous page's future immediately. A new blank page must
    // never remain coupled to an unavailable source from the previous page.
    _assetPreparation = Future<void>.value();
    if (!prepareAssets || _isLegacySketchUnavailable) {
      return;
    }
    _assetPreparation = _prepareCurrentSketchAssets(activation);
  }

  Future<SketchStrokesLoadResult> _hydrateStrokeSourceOnce(SketchData sketch) {
    final pending = _strokeHydrations[sketch];
    if (pending != null) return pending;

    final hydration = SketchStrokesFileService.hydrate(
      sketch,
      passwordProtectedDecoder: widget.note.locked && widget.note.unlocked
          ? widget.note.decryptAttachmentForSession
          : null,
    );
    _strokeHydrations[sketch] = hydration;
    hydration.then<void>(
      (_) {
        if (identical(_strokeHydrations[sketch], hydration)) {
          _strokeHydrations.remove(sketch);
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_strokeHydrations[sketch], hydration)) {
          _strokeHydrations.remove(sketch);
        }
      },
    );
    return hydration;
  }

  bool _canApplySourceResult(SketchSourceActivation activation) =>
      mounted && _sourceController.canApplyHydratedSource(activation);

  bool _isCurrentActivation(SketchSourceActivation activation) =>
      mounted && _sourceController.isCurrent(activation);

  void _activateSketch({
    required SketchData sketch,
    required int index,
    required bool prepareAssets,
    Color? loadingPaperColor,
  }) {
    final backgroundPath = sketch.backgroundImage;
    final isImageBased = backgroundPath != null && backgroundPath.isNotEmpty;
    final cachedBackground = isImageBased && !widget.note.locked
        ? _backgroundImageCache[backgroundPath]
        : null;
    final sourceReady = SketchPageSourceController.isImmediatelyReady(sketch);
    final paperColor = isImageBased
        ? Colors.transparent
        : !sourceReady && loadingPaperColor != null
        ? loadingPaperColor
        : sketch.backgroundColor;
    final canvasSize = cachedBackground != null
        ? Size(
            cachedBackground.width.toDouble(),
            cachedBackground.height.toDouble(),
          )
        : isImageBased && sketch.aspectRatio > 0
        ? Size(kA4Size.width, kA4Size.width / sketch.aspectRatio)
        : kA4Size;

    _pendingDotTimer?.cancel();
    _pendingDotTimer = null;
    _pendingDotPosition = null;
    _pendingDotPressure = null;
    _lastTapTime = null;
    if (_ownsLoadedBackgroundImage) {
      _loadedBackgroundImage?.dispose();
      _ownsLoadedBackgroundImage = false;
    }

    late final SketchSourceActivation activation;
    setState(() {
      activation = _sourceController.activate(sketch);
      _currentSourceActivation = activation;
      _currentSketchIndex = index;
      _sketchData = sketch;
      _strokes = List<SketchStroke>.from(sketch.strokes);
      _undoCount = 0;
      _redoStack.clear();
      _isDirty = false;
      _isImageBasedSketch = isImageBased;
      _paperColor = paperColor;
      _pagePattern = sketch.pagePattern;
      _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;
      _canvasSize = canvasSize;
      _loadedBackgroundImage = cachedBackground;
      _ownsLoadedBackgroundImage = false;
      _backgroundUnavailable = false;
      _isRetryingBackground = false;
      _hasFitted = false;

      // A gesture from the previous page must not finish on this page.
      _currentStroke = null;
      _activePointerCount = 0;
      _isMultiTouch = false;
      _hasStartedDrawing = false;
      _initialTouchPosition = null;
      _cursorPosition = null;
    });
    _beginPreparingCurrentSketch(activation, prepareAssets: prepareAssets);
  }

  /// Hydrates source data before any preview repair. Keeping this sequence in
  /// one future prevents a close or lifecycle save from rendering an image
  /// sketch before its background dimensions are known.
  Future<void> _prepareCurrentSketchAssets(
    SketchSourceActivation activation,
  ) async {
    final sketch = activation.sketch;
    if (!_sourceController.isCurrent(activation)) return;
    var sourceReady = sketch.hasHydratedStrokeSource;
    if (!sketch.hasHydratedStrokeSource) {
      final hydration = await _hydrateStrokeSourceOnce(sketch);
      if (hydration == SketchStrokesLoadResult.legacyPasswordProtected) {
        sketch.markLegacyMigrationFailed(
          'The protected legacy drawing could not be converted yet',
        );
        if (_isCurrentActivation(activation)) setState(() {});
        return;
      }
      sourceReady =
          hydration == SketchStrokesLoadResult.loaded ||
          hydration == SketchStrokesLoadResult.alreadyLoaded ||
          hydration == SketchStrokesLoadResult.empty;
      if (!sourceReady && sketch.hasStrokesFile) return;
    }
    if (!_canApplySourceResult(activation)) return;

    setState(() {
      if (!_sourceController.markHydratedSourceReady(activation)) return;
      _strokes = List<SketchStroke>.from(sketch.strokes);
      _paperColor = _isImageBasedSketch
          ? Colors.transparent
          : sketch.backgroundColor;
      _pagePattern = sketch.pagePattern;
      _selectedColor = isDark(_paperColor) ? Colors.white : Colors.black;
    });

    if (sketch.backgroundImage != null && sketch.backgroundImage!.isNotEmpty) {
      try {
        await _loadBackgroundImage(activation);
      } catch (e, stackTrace) {
        AppLogger.error('Error loading sketch background', e, stackTrace);
        if (_isCurrentActivation(activation)) {
          setState(() => _backgroundUnavailable = true);
        }
        return;
      }
    }

    if (!_isCurrentActivation(activation)) return;
    final previewPath = sketch.previewImage;
    final fs = await fileSystem();
    final previewMissing =
        previewPath == null ||
        previewPath.isEmpty ||
        previewPath.startsWith('http') ||
        !await fs.exists(previewPath);
    if (!_isCurrentActivation(activation)) return;
    if (!previewMissing) return;

    if (widget.note.locked && widget.note.unlocked) {
      await SketchPreviewRepairService.repairAfterUnlock(widget.note);
    } else if (!widget.note.locked) {
      await SketchPreviewRepairService.repairMissingPreviews(widget.note);
    }
    if (_isCurrentActivation(activation)) setState(() {});
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
    if (_ownsLoadedBackgroundImage) {
      _loadedBackgroundImage?.dispose();
    }
    _pagesPopupController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _autoSaveTimer?.cancel();
    _pendingDotTimer?.cancel();
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

  _PendingSaveState _captureSaveState() => _PendingSaveState(
    sketchData: _sketchData,
    strokes: List<SketchStroke>.from(_strokes),
    paperColor: _paperColor,
    pagePattern: _pagePattern,
    canvasSize: _canvasSize,
    isImageBasedSketch: _isImageBasedSketch,
    loadedBackgroundImage: _loadedBackgroundImage,
    note: widget.note,
    sourceAttachment: widget.sourceAttachment,
    localSketches: _localSketches,
    saveToken: _saveGenerations.capture(_sketchData),
    revision: _editRevision,
    onIndexUpdate: (index) {
      if (mounted) setState(() => _currentSketchIndex = index);
    },
  );

  /// Execute the pending save with captured state
  Future<_SketchSaveResult> _executePendingSave(_PendingSaveState state) async {
    if (!_saveGenerations.isCurrent(state.saveToken)) {
      return _SketchSaveResult.cancelled;
    }
    await SketchPage.beforeCapturedSaveOverride?.call(state.saveToken);
    if (!_saveGenerations.isCurrent(state.saveToken)) {
      return _SketchSaveResult.cancelled;
    }
    if (state.sketchData.requiresLegacyMigration) {
      return _SketchSaveResult.unchanged;
    }
    if (state.strokes.isEmpty) {
      if (state.note.hasSketch(state.sketchData)) {
        await state.note.removeSketch(state.sketchData);
      }
      return _SketchSaveResult.saved;
    }

    final createdPaths = <String>[];
    try {
      await state.note.persistSketchMutation(() async {
        _throwIfStale(state);
        final bodySize = state.canvasSize;
        final pngBytes = await SketchRenderer.renderPng(
          strokes: state.strokes,
          sourceCanvasSize: bodySize,
          outputSize: bodySize,
          backgroundColor: state.paperColor,
          pagePattern: state.pagePattern,
          isImageBased: state.isImageBasedSketch,
          backgroundImage: state.loadedBackgroundImage,
        );
        _throwIfStale(state);

        final compressedBytes = await _compressSketchPreview(pngBytes);
        _throwIfStale(state);

        final fs = await fileSystem();
        // Reuse existing preview path or create new one (only if valid local path)
        final existingPreviewPath = state.sketchData.previewImage;
        String previewPath;
        if (existingPreviewPath != null &&
            existingPreviewPath.isNotEmpty &&
            !existingPreviewPath.startsWith('http')) {
          previewPath = existingPreviewPath;
        } else {
          previewPath = path.join(await fs.documentDir, '${Uuid().v4()}.jpg');
          createdPaths.add(previewPath);
        }
        _throwIfStale(state);
        await _writeSketchFile(
          state.note,
          previewPath,
          compressedBytes,
          cacheImage: true,
        );
        _throwIfStale(state);

        // Generate tiny thumbnail for locked note preview (under 1KB)
        final thumbnail = await ThumbnailGenerator.generateFromBytes(
          compressedBytes,
        );
        _throwIfStale(state);

        // Reuse existing strokes file path or create new one (only if valid local path)
        final existingStrokesPath = state.sketchData.strokesFilePath;
        String strokesFilePath;
        if (existingStrokesPath != null &&
            existingStrokesPath.isNotEmpty &&
            !existingStrokesPath.startsWith('http')) {
          strokesFilePath = existingStrokesPath;
        } else {
          strokesFilePath = path.join(
            await fs.documentDir,
            '${Uuid().v4()}.json',
          );
          createdPaths.add(strokesFilePath);
        }
        final preparedSketch = SketchData(
          strokes: List<SketchStroke>.from(state.strokes),
          aspectRatio: bodySize.width / bodySize.height,
          backgroundColor: state.paperColor,
          pagePattern: state.pagePattern,
          previewImage: previewPath,
          backgroundImage: state.sketchData.backgroundImage,
          blurredThumbnail: thumbnail,
          strokesFilePath: strokesFilePath,
          strokesContentHash: state.sketchData.strokesContentHash,
          strokesHydrated: true,
        );
        final strokesJson = json.encode(preparedSketch.toStrokesFileJson());
        // Await strokes file write - must complete before note save triggers sync
        _throwIfStale(state);
        await _writeSketchFile(
          state.note,
          strokesFilePath,
          Uint8List.fromList(utf8.encode(strokesJson)),
        );
        _throwIfStale(state);

        // Publish only after both required files are complete. Locking cannot
        // observe this object until this queued mutation finishes.
        state.sketchData
          ..strokes = preparedSketch.strokes
          ..backgroundColor = preparedSketch.backgroundColor
          ..pagePattern = preparedSketch.pagePattern
          ..previewImage = preparedSketch.previewImage
          ..aspectRatio = preparedSketch.aspectRatio
          ..blurredThumbnail = preparedSketch.blurredThumbnail
          ..strokesFilePath = preparedSketch.strokesFilePath;
        state.sketchData.markStrokesHydrated();

        if (state.isImageBasedSketch && state.sourceAttachment != null) {
          state.sourceAttachment!.type = AttachmentType.sketch;
          state.sourceAttachment!.sketch = state.sketchData;
          state.sourceAttachment!.image = null;
        } else if (!state.note.hasSketch(state.sketchData)) {
          state.note.attachments.add(NoteAttachment.sketch(state.sketchData));
        }
      });
    } on _StaleSketchSave {
      await _deleteCreatedSaveFiles(createdPaths);
      return _SketchSaveResult.cancelled;
    }

    if (!_saveGenerations.isCurrent(state.saveToken)) {
      return _SketchSaveResult.cancelled;
    }
    if (!state.localSketches.contains(state.sketchData)) {
      state.localSketches.add(state.sketchData);
      state.onIndexUpdate?.call(state.localSketches.indexOf(state.sketchData));
    }
    return _SketchSaveResult.saved;
  }

  void _throwIfStale(_PendingSaveState state) {
    if (!_saveGenerations.isCurrent(state.saveToken)) {
      throw const _StaleSketchSave();
    }
  }

  Future<void> _deleteCreatedSaveFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    final fs = await fileSystem();
    for (final filePath in paths) {
      try {
        if (await fs.exists(filePath)) await fs.delete(filePath);
        UniversalImageCache.instance.invalidate(filePath);
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to clean a cancelled sketch save file',
          error,
          stackTrace,
        );
      }
    }
  }

  /// Navigate to a different sketch by index
  Future<void> _navigateToSketch(int index) async {
    if (index < 0 || index >= _totalSketches) return;
    if (index == _currentSketchIndex) return;

    final savedSketchCount = _localSketches.length;
    final isCurrentlyOnPendingSketch =
        _pendingNewSketch != null && _currentSketchIndex >= savedSketchCount;

    // Only save if there are actual changes (dirty) and has content
    if (_isDirty && _strokes.isNotEmpty) {
      if (!await _save()) return;
      // Only clear pending if we just saved the pending sketch (it's now in _localSketches)
      if (isCurrentlyOnPendingSketch) {
        _pendingNewSketch = null;
      }
    }
    // If on empty pending sketch, keep it stored so we can navigate back

    // Check if navigating to the pending new sketch position
    final isNavigatingToPendingSketch = index >= _localSketches.length;

    if (isNavigatingToPendingSketch && _pendingNewSketch != null) {
      // Navigate to the pending new sketch
      _activateSketch(
        sketch: _pendingNewSketch!,
        index: index,
        prepareAssets: false,
      );
      return;
    }

    if (isNavigatingToPendingSketch) {
      // No pending sketch to navigate to
      return;
    }

    _activateSketch(
      sketch: _localSketches[index],
      index: index,
      prepareAssets: true,
      loadingPaperColor: _paperColor,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_save().then<void>((_) {}));
    }
  }

  /// Delete the current sketch and navigate to next or previous
  Future<void> _deleteCurrentSketch() async {
    if (_isDeleting) return;
    final confirm = await showDeleteDialog(context, title: 'Delete Sketch?');

    if (confirm != true) return;

    final deletedSketch = _sketchData;
    _isDeleting = true;
    _saveGenerations.tombstone(deletedSketch);
    _autoSaveTimer?.cancel();
    _pendingDotTimer?.cancel();

    try {
      await _pageOperations.run(
        () => _deleteSketchWithinPageQueue(deletedSketch),
      );
    } catch (error, stackTrace) {
      _saveGenerations.restore(deletedSketch);
      AppLogger.error('Failed to delete sketch', error, stackTrace);
      if (mounted) {
        snackbar('Failed to delete sketch', Colors.red);
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  Future<void> _deleteSketchWithinPageQueue(SketchData deletedSketch) async {
    final isOnPendingSketch = identical(_pendingNewSketch, deletedSketch);
    final deletedIndex = _localSketches.indexOf(deletedSketch);

    // A captured save that reached SQLite before seeing the tombstone is
    // removed here. This makes confirmed deletion the final operation.
    if (widget.note.hasSketch(deletedSketch)) {
      await widget.note.removeSketch(deletedSketch);
    }

    if (isOnPendingSketch) {
      _pendingNewSketch = null;
    } else if (deletedIndex >= 0) {
      _localSketches.removeAt(deletedIndex);
    }

    _isDirty = false;

    if (_localSketches.isEmpty && _pendingNewSketch == null) {
      if (mounted) {
        Navigator.pop(context);
      }
      return;
    }

    int newIndex;
    if (_pendingNewSketch != null) {
      newIndex = _localSketches.length;
    } else if (isOnPendingSketch) {
      newIndex = _localSketches.length - 1;
    } else if (deletedIndex < _localSketches.length) {
      newIndex = max(0, deletedIndex);
    } else {
      newIndex = _localSketches.length - 1;
    }

    final newSketch = newIndex < _localSketches.length
        ? _localSketches[newIndex]
        : _pendingNewSketch!;

    final isPendingSketch = identical(newSketch, _pendingNewSketch);
    _activateSketch(
      sketch: newSketch,
      index: newIndex,
      prepareAssets: !isPendingSketch,
      loadingPaperColor: _paperColor,
    );
  }

  /// Create a new blank sketch
  void _createNewSketch() async {
    // Capture current sketch settings before saving
    final currentBgColor = _paperColor;
    final currentPagePattern = _pagePattern;

    // Save current sketch first if it has strokes
    if (_strokes.isNotEmpty) {
      if (!await _save()) return;
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

    _pendingNewSketch = newSketch;
    _activateSketch(
      sketch: newSketch,
      index: _localSketches.length,
      prepareAssets: false,
    );
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
    if (_isLegacySketchUnavailable) {
      return Scaffold(
        backgroundColor: _backgroundColor,
        appBar: AppBar(
          backgroundColor: _backgroundColor,
          foregroundColor: _foregroundColor,
          title: Text(context.l10n.protectedSketchTitle),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 56,
                  color: _foregroundColor.withValues(alpha: 0.7),
                ),
                const SizedBox(height: 16),
                Text(
                  context.l10n.protectedSketchRecoveryMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _foregroundColor, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_isClosing || _isDeleting) return;
        _isClosing = true;
        await _assetPreparation;
        if (!mounted || !context.mounted) return;
        var saved = await _save();
        while (saved && _isDirty) {
          saved = await _save();
        }
        if (!saved) {
          _isClosing = false;
          return;
        }
        if (!mounted || !context.mounted) return;
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
                              passwordProtectedDecoder:
                                  widget.note.locked && widget.note.unlocked
                                  ? widget.note.decryptAttachmentForSession
                                  : null,
                            ),
                          ),
                        // Page pattern layer - rendered dynamically, not saved in preview
                        if (!_isImageBasedSketch &&
                            _pagePattern != PagePattern.blank)
                          Positioned.fill(
                            child: PagePatternBackground(
                              pattern: _pagePattern,
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
                                if (widget.note.readOnly ||
                                    _isMoveMode ||
                                    !_isCanvasReady) {
                                  return;
                                }
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
                                if (widget.note.readOnly ||
                                    _isMoveMode ||
                                    !_isCanvasReady) {
                                  return;
                                }
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
                                if (widget.note.readOnly ||
                                    _isMoveMode ||
                                    !_isCanvasReady) {
                                  return;
                                }
                                setState(() {
                                  if (_activePointerCount > 0) {
                                    _activePointerCount--;
                                  }
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
                                if (widget.note.readOnly ||
                                    _isMoveMode ||
                                    !_isCanvasReady) {
                                  return;
                                }
                                setState(() {
                                  if (_activePointerCount > 0) {
                                    _activePointerCount--;
                                  }
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
                                      passwordProtectedDecoder:
                                          widget.note.locked &&
                                              widget.note.unlocked
                                          ? widget
                                                .note
                                                .decryptAttachmentForSession
                                          : null,
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
            if (_isImageBasedSketch && _backgroundUnavailable)
              Positioned.fill(
                child: SafeArea(
                  child: Center(
                    child: Card(
                      margin: const EdgeInsets.all(24),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.image_not_supported_outlined),
                            const SizedBox(height: 12),
                            Text(
                              context.l10n.sketchBackgroundUnavailable,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: _isRetryingBackground
                                  ? null
                                  : _retryBackground,
                              icon: _isRetryingBackground
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.refresh),
                              label: Text(context.l10n.retry),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
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
                                          _sourceController.recordStrokeEdit();
                                          _editRevision++;
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
                                          _sourceController.recordStrokeEdit();
                                          _editRevision++;
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
                                      _pagePattern.icon,
                                      color: _foregroundColor,
                                    ),
                                    tooltip: context.l10n.pagePattern,
                                    onSelected: (pattern) {
                                      setState(() {
                                        _pagePattern = pattern;
                                        _editRevision++;
                                        _isDirty = true;
                                      });
                                    },
                                    itemBuilder: (context) =>
                                        PagePattern.values.map((pattern) {
                                          final isSelected =
                                              _pagePattern == pattern;
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
                                    if (_strokes.isNotEmpty && _isCanvasReady)
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
            onTap: () async {
              close();
              await _navigateToSketch(index);
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
                        passwordProtectedDecoder:
                            widget.note.locked && widget.note.unlocked
                            ? widget.note.decryptAttachmentForSession
                            : null,
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

  Future<void> _loadBackgroundImage(SketchSourceActivation activation) async {
    final sketch = activation.sketch;
    final bgImage = sketch.backgroundImage!;

    // Check cache first
    if (!widget.note.locked && _backgroundImageCache.containsKey(bgImage)) {
      final cachedImage = _backgroundImageCache[bgImage]!;
      if (!_canApplySourceResult(activation)) return;
      setState(() {
        _loadedBackgroundImage = cachedImage;
        _ownsLoadedBackgroundImage = false;
        _backgroundUnavailable = false;
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

    final data = await widget.note.readAttachmentForSession(bgImage);
    final codec = await ui.instantiateImageCodec(data);
    final frame = await codec.getNextFrame();
    codec.dispose();

    // Authenticated plaintext must remain scoped to this page. Public image
    // backgrounds retain the global cache used for smooth navigation.
    if (!widget.note.locked) {
      if (_backgroundImageCache.length >= _maxImageCacheSize) {
        final oldestKey = _backgroundImageCache.keys.first;
        _backgroundImageCache.remove(oldestKey)?.dispose();
      }
      _backgroundImageCache[bgImage] = frame.image;
    }

    if (!_canApplySourceResult(activation)) {
      if (widget.note.locked) frame.image.dispose();
      return;
    }

    setState(() {
      _loadedBackgroundImage = frame.image;
      _ownsLoadedBackgroundImage = widget.note.locked;
      _backgroundUnavailable = false;
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

  Future<void> _retryBackground() async {
    if (_isRetryingBackground || !_isImageBasedSketch) return;
    final activation = _currentSourceActivation;
    final originalPath = activation.sketch.backgroundImage;
    if (originalPath == null || originalPath.isEmpty) return;

    setState(() => _isRetryingBackground = true);
    try {
      String? recoveredPath;
      if (originalPath.startsWith('http://') ||
          originalPath.startsWith('https://')) {
        recoveredPath = await NoteSyncService().retryRemoteAttachmentDownload(
          originalPath,
          widget.note,
        );
      } else {
        final fs = await fileSystem();
        if (!await fs.exists(originalPath)) {
          recoveredPath = await NoteSyncService().redownloadFile(originalPath);
        }
      }
      if (!_isCurrentActivation(activation)) return;
      if (recoveredPath != null && recoveredPath.isNotEmpty) {
        activation.sketch.backgroundImage = recoveredPath;
      }

      await _loadBackgroundImage(activation);
      if (!_isCurrentActivation(activation)) return;
      if (widget.note.locked && widget.note.unlocked) {
        await SketchPreviewRepairService.repairAfterUnlock(widget.note);
      } else if (!widget.note.locked) {
        await SketchPreviewRepairService.repairMissingPreviews(widget.note);
      }
    } catch (error, stackTrace) {
      AppLogger.error('Sketch background retry failed', error, stackTrace);
      if (_isCurrentActivation(activation)) {
        setState(() => _backgroundUnavailable = true);
      }
    } finally {
      if (_isCurrentActivation(activation)) {
        setState(() => _isRetryingBackground = false);
      }
    }
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
    if (_isClosing || _isDeleting) return;
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
    if (_isClosing || _isDeleting) return;
    setState(() {
      if (_currentStroke != null) {
        // Use full precision for x,y for buttery smooth Bezier curves
        _currentStroke!.points +=
            ';$x,$y,${(pressure ?? 0.5).toStringAsFixed(3)}';
      }
    });
  }

  void _endStroke() {
    if (_isClosing || _isDeleting) return;
    setState(() {
      if (_currentStroke != null) {
        ++_undoCount;
        _redoStack.clear();
        _strokes.add(_currentStroke!);
        _sourceController.recordStrokeEdit();
        _currentStroke = null;
        _editRevision++;
        _isDirty = true;
      }
    });

    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 3), _save);
  }

  /// Place a dot at the given position (for quick taps)
  void _placeDot(double x, double y, double? pressure) {
    if (_isClosing || _isDeleting) return;
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
      _sourceController.recordStrokeEdit();
      _editRevision++;
      _isDirty = true;
    });

    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 3), _save);
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

  static Future<void> _writeSketchFile(
    Note note,
    String filePath,
    Uint8List plaintext, {
    bool cacheImage = false,
  }) async {
    await note.writeAttachmentForSession(filePath, plaintext);
    if (!cacheImage) return;
    if (note.locked) {
      UniversalImageCache.instance.invalidate(filePath);
    } else {
      UniversalImageCache.instance.put(filePath, filePath, plaintext);
    }
  }

  Future<bool> _save() => _pageOperations.run(_saveWithinPageQueue);

  Future<bool> _saveWithinPageQueue() async {
    if (_isLegacySketchUnavailable) return true;
    if (_saveGenerations.isDeleted(_sketchData)) return true;
    if (!_isCanvasReady) return !_isDirty;
    if (_currentStroke != null) {
      _autoSaveTimer?.cancel();
      _autoSaveTimer = Timer(const Duration(seconds: 3), _save);
      return false;
    }

    _autoSaveTimer?.cancel();
    if (!_isDirty) return true;

    final state = _captureSaveState();
    try {
      final result = await _executePendingSave(state);
      if (result == _SketchSaveResult.cancelled) return true;
      if (_saveGenerations.isCurrent(state.saveToken) &&
          identical(state.sketchData, _sketchData) &&
          state.revision == _editRevision) {
        _isDirty = false;
        _pendingNewSketch = null;
      }
      return true;
    } catch (error, stackTrace) {
      AppLogger.error('Error saving sketch', error, stackTrace);
      if (mounted) {
        snackbar(context.l10n.errorSavingSketch(error.toString()), Colors.red);
      }
      return false;
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
          _editRevision++;
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
    if (!_isCanvasReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.sketchBackgroundUnavailable)),
        );
      }
      return;
    }
    try {
      final bodySize = _canvasSize;
      final pngBytes = await SketchRenderer.renderPng(
        strokes: _strokes,
        sourceCanvasSize: bodySize,
        outputSize: bodySize,
        backgroundColor: _paperColor,
        pagePattern: _pagePattern,
        isImageBased: _isImageBasedSketch,
        backgroundImage: _loadedBackgroundImage,
      );

      final fs = await fileSystem();
      final index = _localSketches.indexOf(_sketchData);
      final fileName = 'sketch_${widget.note.id}_$index.png';

      final success = await fs.saveToGallery(pngBytes, fileName);

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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.errorSavingSketch(e.toString()))),
        );
      }
    }
  }
}

/// Immutable state captured for one ordered sketch save operation.
class _PendingSaveState {
  final SketchData sketchData;
  final List<SketchStroke> strokes;
  final Color paperColor;
  final PagePattern pagePattern;
  final Size canvasSize;
  final bool isImageBasedSketch;
  final ui.Image? loadedBackgroundImage;
  final Note note;
  final NoteAttachment? sourceAttachment;
  final List<SketchData> localSketches;
  final SketchSaveToken saveToken;
  final int revision;
  final void Function(int)? onIndexUpdate;

  _PendingSaveState({
    required this.sketchData,
    required this.strokes,
    required this.paperColor,
    required this.pagePattern,
    required this.canvasSize,
    required this.isImageBasedSketch,
    required this.loadedBackgroundImage,
    required this.note,
    required this.sourceAttachment,
    required this.localSketches,
    required this.saveToken,
    required this.revision,
    this.onIndexUpdate,
  });
}
