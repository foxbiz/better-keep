import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:better_keep/components/animated_icon.dart';
import 'package:better_keep/components/note_image_grid.dart';
import 'package:better_keep/dialogs/unlock_note_dialog.dart';
import 'package:better_keep/dialogs/reminder.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/quill_config.dart';
import 'package:better_keep/utils/thumbnail_generator.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:better_keep/utils/week_days.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';

class NoteCard extends StatefulWidget {
  final Note note;
  final int index;

  const NoteCard({super.key, required this.note, required this.index});

  /// Locked-note content is only revealed inside an authenticated editor.
  /// Keeping [unlocked] in this policy interface prevents a future caller from
  /// accidentally treating a cached PIN as permission to reveal home-card
  /// attachments.
  @visibleForTesting
  static bool usesPrivateAttachmentPresentation({
    required bool locked,
    required bool unlocked,
  }) => locked;

  /// Recording titles are content and remain private on every locked card,
  /// even while a cached PIN keeps the editor temporarily unlocked.
  @visibleForTesting
  static bool showsRecordingTitle({
    required bool locked,
    required bool unlocked,
  }) => !locked;

  /// Produces card-only attachment models which contain no full local path.
  ///
  /// The locked grid renders only [NoteImage.blurredThumbnail]. Keeping the
  /// original source out of the grid also makes a future rendering regression
  /// fail closed instead of revealing the full attachment.
  @visibleForTesting
  static List<NoteImage> privateAttachmentPresentations(Note note) => [
    for (final image in note.images)
      NoteImage(
        src: '',
        size: image.size,
        index: image.index,
        aspectRatio: image.aspectRatio,
        lastModified: image.lastModified,
        blurredThumbnail: image.blurredThumbnail,
      ),
    for (final (index, sketch) in note.sketches.indexed)
      NoteImage(
        src: '',
        size: 0,
        index: note.images.length + index,
        aspectRatio:
            '${((sketch.aspectRatio > 0 ? sketch.aspectRatio : 1.0) * 1000).round()}:1000',
        lastModified: '',
        blurredThumbnail: sketch.blurredThumbnail,
      ),
  ];

  /// Clear the static base64 image cache to free memory.
  static void clearImageCache() {
    _NoteCardState._base64ImageCache.clear();
  }

  @override
  State<NoteCard> createState() => _NoteCardState();
}

/// Owns the read-only document used by a note card.
///
/// Lock removal can change presentation access without changing the note's
/// content bytes, so this cache must be synchronized with both values.
@visibleForTesting
class NoteCardBodyCache {
  QuillController? _controller;

  QuillController? get controller => _controller;

  void update({required bool locked, required Document? document}) {
    if (locked || document == null) {
      _controller?.dispose();
      _controller = null;
      return;
    }

    if (_controller == null) {
      _controller = QuillController(
        readOnly: true,
        document: document,
        selection: const TextSelection.collapsed(offset: 0),
      );
    } else {
      _controller!.document = document;
    }
  }

  void dispose() {
    _controller?.dispose();
    _controller = null;
  }
}

/// Compact audio presentation used by note cards.
///
/// A locked card exposes only the recording count. Recording titles remain
/// available on ordinary cards and inside the authenticated editor.
class NoteCardAudioIndicator extends StatelessWidget {
  final String? recordingTitle;
  final int? recordingCount;
  final bool locked;
  final Color foregroundColor;

  const NoteCardAudioIndicator({
    super.key,
    this.recordingTitle,
    this.recordingCount,
    required this.locked,
    required this.foregroundColor,
  }) : assert(!locked || (recordingCount != null && recordingCount > 0));

  @override
  Widget build(BuildContext context) {
    final label = locked
        ? context.l10n.audioCount(recordingCount!)
        : recordingTitle ?? context.l10n.audio;
    final indicator = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: foregroundColor.withAlpha(50)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.play_circle_outline, size: 16, color: foregroundColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: foregroundColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (!locked) return indicator;
    return Semantics(
      label: context.l10n.audio,
      excludeSemantics: true,
      child: indicator,
    );
  }
}

/// Collapses protected recordings into one count badge while preserving the
/// per-recording presentation for ordinary cards.
class NoteCardAudioGroup extends StatelessWidget {
  final List<NoteRecording> recordings;
  final bool locked;
  final Color foregroundColor;

  const NoteCardAudioGroup({
    super.key,
    required this.recordings,
    required this.locked,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    if (recordings.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: locked
          ? [
              NoteCardAudioIndicator(
                recordingCount: recordings.length,
                locked: true,
                foregroundColor: foregroundColor,
              ),
            ]
          : [
              for (final recording in recordings)
                NoteCardAudioIndicator(
                  recordingTitle: recording.title,
                  locked: false,
                  foregroundColor: foregroundColor,
                ),
            ],
    );
  }
}

class _ReminderCardActions extends StatelessWidget {
  static const double _iconSize = 20;
  static const double _iconLabelSpacing = 6;
  static const double _horizontalPadding = 10;
  static const double _actionSpacing = 4;
  static const double _minimumTouchTarget = 48;

  final bool showDone;
  final Color foregroundColor;
  final Future<void> Function() onDone;
  final Future<void> Function() onRemove;

  const _ReminderCardActions({
    required this.showDone,
    required this.foregroundColor,
    required this.onDone,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final actions =
        <
          ({
            String label,
            IconData icon,
            Color color,
            Future<void> Function() onPressed,
          })
        >[
          if (showDone)
            (
              label: context.l10n.done,
              icon: Icons.done,
              color: foregroundColor,
              onPressed: onDone,
            ),
          (
            label: context.l10n.remove,
            icon: Icons.notifications_off_outlined,
            color: Colors.red.shade400,
            onPressed: onRemove,
          ),
        ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final textStyle = Theme.of(context).textTheme.labelLarge;
        final labeledWidth =
            actions.fold<double>(
              0,
              (width, action) =>
                  width + _labeledActionWidth(context, action.label, textStyle),
            ) +
            _actionSpacing * (actions.length - 1);
        final showLabels =
            !constraints.hasBoundedWidth ||
            constraints.maxWidth >= labeledWidth;

        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final (index, action) in actions.indexed) ...[
              if (index > 0) const SizedBox(width: _actionSpacing),
              _buildAction(action, showLabel: showLabels),
            ],
          ],
        );
      },
    );
  }

  double _labeledActionWidth(
    BuildContext context,
    String label,
    TextStyle? style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return max(
      _minimumTouchTarget,
      _horizontalPadding * 2 + _iconSize + _iconLabelSpacing + width,
    );
  }

  Widget _buildAction(
    ({
      String label,
      IconData icon,
      Color color,
      Future<void> Function() onPressed,
    })
    action, {
    required bool showLabel,
  }) {
    if (showLabel) {
      return Tooltip(
        message: action.label,
        child: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: action.color,
            minimumSize: const Size(_minimumTouchTarget, _minimumTouchTarget),
            padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
          ),
          onPressed: action.onPressed,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(action.icon, size: _iconSize),
              const SizedBox(width: _iconLabelSpacing),
              Text(
                action.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      label: action.label,
      excludeSemantics: true,
      child: IconButton(
        tooltip: action.label,
        color: action.color,
        iconSize: _iconSize,
        constraints: const BoxConstraints(
          minWidth: _minimumTouchTarget,
          minHeight: _minimumTouchTarget,
        ),
        onPressed: action.onPressed,
        icon: Icon(action.icon),
      ),
    );
  }
}

class _NoteCardState extends State<NoteCard>
    with SingleTickerProviderStateMixin {
  static final Map<String, MemoryImage> _base64ImageCache = {};
  static const int _maxImageCacheSize = 100;

  bool _isSelected = false;
  bool _selectionMode = false;
  bool _isSyncingOutgoing = false;
  bool _isSyncingIncoming = false;
  bool _isSyncFailed = false;
  String? _syncStatus;
  final NoteCardBodyCache _bodyCache = NoteCardBodyCache();
  QuillController? get _controller => _bodyCache.controller;
  Timer? _noteReminderExpiration;

  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  final _focusNode = FocusNode(canRequestFocus: false);
  final _scrollController = ScrollController();

  String? _lastContent;
  late bool _lastLocked;
  Reminder? _lastReminder;
  int _lastMaxChars = 500;

  /// Returns true if the note content contains a decryption_failed error
  /// This happens when E2EE decryption fails and the note cannot be recovered
  bool get _hasDecryptionError {
    return widget.note.content == Note.decryptionFailedContent;
  }

  /// Returns max chars based on screen width (1000 for bigger screens, 500 for smaller)
  int _getMaxChars(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return screenWidth > 600 ? 1000 : 500;
  }

  /// Creates a truncated document limited to maxChars characters
  /// Preserves Delta attributes (checkboxes, formatting, etc.) during truncation
  Document? _createTruncatedDocument(Document? doc, {int maxChars = 500}) {
    if (doc == null) return null;

    final plainText = doc.toPlainText();
    if (plainText.length <= maxChars) return doc;

    // Iterate through Delta operations preserving attributes
    final delta = doc.toDelta();
    final newOps = <Map<String, dynamic>>[];
    int charCount = 0;
    bool truncated = false;

    for (final op in delta.toList()) {
      if (!op.isInsert || truncated) continue;

      final data = op.data;
      final attributes = op.attributes;

      if (data is String) {
        final remaining = maxChars - charCount;
        if (remaining <= 0) {
          truncated = true;
          continue;
        }

        if (data.length <= remaining) {
          // Include entire operation with its attributes
          newOps.add(op.toJson());
          charCount += data.length;
        } else {
          // Truncate this text segment and add ellipsis
          newOps.add({
            'insert': '...',
            'attributes': {'italic': true, 'color': 'grey'},
          });
          truncated = true;
        }
      } else {
        // Embeds (images, etc.) - include as-is, don't count toward char limit
        newOps.add({'insert': data, 'attributes': ?attributes});
      }
    }

    // Ensure document ends with newline (required by Quill)
    if (newOps.isEmpty) {
      newOps.add({'insert': '\n'});
    } else {
      final lastInsert = newOps.last['insert'];
      if (lastInsert is String && !lastInsert.endsWith('\n')) {
        newOps.add({'insert': '\n'});
      }
    }

    return Document.fromJson(newOps);
  }

  @override
  void initState() {
    final selectedNotes = AppState.selectedNotes;
    final doc = widget.note.document;
    final note = widget.note;

    _lastContent = note.content;
    _lastLocked = note.locked;
    _lastReminder = note.reminder;

    // Listen for sync state changes
    NoteSyncService().syncingOutgoing.addListener(_onSyncStateChanged);
    NoteSyncService().syncingIncoming.addListener(_onSyncStateChanged);
    NoteSyncService().syncFailed.addListener(_onSyncStateChanged);
    NoteSyncService().noteStatus.addListener(_onSyncStateChanged);
    _updateSyncState();

    _scheduleReminderExpiration();

    _bodyCache.update(
      locked: note.locked,
      document: doc == null ? null : _createTruncatedDocument(doc) ?? doc,
    );

    _selectionMode = selectedNotes.isNotEmpty;
    if (selectedNotes.isNotEmpty) {
      _isSelected = selectedNotes.any((n) => n.id == note.id);
    }

    AppState.subscribe("selected_notes", _selectedNotesListener);

    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic);
    _slide = Tween(
      begin: const Offset(0, -.5),
      end: Offset.zero,
    ).animate(_fade);

    final delay = Duration(milliseconds: min(widget.index * 24, 1000));
    Future.delayed(delay, () {
      if (mounted) _anim.forward();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _anim.forward());

    super.initState();
  }

  @override
  void didUpdateWidget(NoteCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    final contentChanged = widget.note.content != _lastContent;
    final lockedChanged = widget.note.locked != _lastLocked;
    final reminderChanged = widget.note.reminder != _lastReminder;

    if (widget.note != oldWidget.note || contentChanged || lockedChanged) {
      _lastContent = widget.note.content;
      _lastLocked = widget.note.locked;
      _syncBodyController();
    }

    // Update reminder timer if needed
    if (widget.note != oldWidget.note || reminderChanged) {
      _lastReminder = widget.note.reminder;
      _scheduleReminderExpiration();
    }
  }

  void _scheduleReminderExpiration() {
    _noteReminderExpiration?.cancel();
    final note = widget.note;
    if (!note.hasReminder || note.hasReminderExpired) return;
    final delay = note.reminder!.overdueAt.difference(DateTime.now());
    if (delay <= Duration.zero) return;
    _noteReminderExpiration = Timer(delay, () {
      if (mounted) setState(() {});
    });
  }

  /// Keeps the body cache aligned with the note's privacy state.
  ///
  /// Lock removal mutates the existing [Note] instance, so content can remain
  /// byte-for-byte unchanged while becoming safe to display. Conversely, a
  /// newly locked note must immediately discard any previously rendered body.
  void _syncBodyController() {
    final document = widget.note.document;
    _bodyCache.update(
      locked: widget.note.locked,
      document: document == null
          ? null
          : _createTruncatedDocument(document) ?? document,
    );
  }

  void _onSyncStateChanged() {
    _updateSyncState();
  }

  void _updateSyncState() {
    if (!mounted) return;
    final noteId = widget.note.id;
    if (noteId == null) return;

    final isOutgoing = NoteSyncService().syncingOutgoing.value.contains(noteId);
    final isIncoming = NoteSyncService().syncingIncoming.value.contains(noteId);
    final isFailed = NoteSyncService().syncFailed.value.contains(noteId);
    final status = NoteSyncService().noteStatus.value[noteId];

    if (isOutgoing != _isSyncingOutgoing ||
        isIncoming != _isSyncingIncoming ||
        isFailed != _isSyncFailed ||
        status != _syncStatus) {
      setState(() {
        _isSyncingOutgoing = isOutgoing;
        _isSyncingIncoming = isIncoming;
        _isSyncFailed = isFailed;
        _syncStatus = status;
      });
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _bodyCache.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _noteReminderExpiration?.cancel();
    NoteSyncService().syncingOutgoing.removeListener(_onSyncStateChanged);
    NoteSyncService().syncingIncoming.removeListener(_onSyncStateChanged);
    NoteSyncService().syncFailed.removeListener(_onSyncStateChanged);
    NoteSyncService().noteStatus.removeListener(_onSyncStateChanged);
    AppState.unsubscribe("selected_notes", _selectedNotesListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Update truncation if screen size changed
    final maxChars = _getMaxChars(context);
    if (maxChars != _lastMaxChars && _controller != null) {
      _lastMaxChars = maxChars;
      final doc = widget.note.document;
      if (!widget.note.locked && doc != null) {
        _controller!.document =
            _createTruncatedDocument(doc, maxChars: maxChars) ?? doc;
      }
    }

    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onTap: _handleTap,
          onLongPress: _selectionMode ? null : _toggleSelection,
          child: _buildCard(),
        ),
      ),
    );
  }

  Future<void> _handleTap() async {
    if (_selectionMode) {
      _toggleSelection();
      return;
    }

    // Handle decryption-failed notes - offer retry or permanent deletion
    if (_hasDecryptionError) {
      final l10n = context.l10n;
      final action = await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            icon: const Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange,
              size: 40,
            ),
            title: Text(l10n.encryptedNote),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.decryptionFailedRetryMessage),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.red.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning, color: Colors.red, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.deletingNoteFromAllDevicesWarning,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: Text(l10n.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'delete'),
                child: Text(
                  l10n.deleteForever,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, 'retry'),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.retryDecryption),
              ),
            ],
          );
        },
      );
      if (!mounted) return;
      if (action == 'retry') {
        if (E2EEService.instance.isReady && E2EEService.instance.isAvailable) {
          if (NoteSyncService().isSyncing.value) {
            snackbar(l10n.syncing);
          } else {
            snackbar(l10n.retryingDecryption);
            final success = await NoteSyncService().retryDecryptionForNote(
              widget.note.id!,
            );
            if (!success && mounted) {
              snackbar(l10n.decryptionFailed);
            }
          }
        } else {
          snackbar(l10n.e2eeNotReady);
        }
      } else if (action == 'delete') {
        await widget.note.delete();
        snackbar(l10n.noteDeletedPermanently);
      }
      return;
    }

    if (widget.note.locked && !widget.note.unlocked) {
      final unlocked = await showUnlockNoteDialog(context, widget.note);
      if (unlocked != true) {
        return;
      }
    }

    if (mounted) {
      showPage(context, NoteEditor(note: widget.note), allowFullScreen: true);
    }
  }

  void _showNoteJson() {
    final jsonEncoder = const JsonEncoder.withIndent('  ');

    // Get raw JSON and decode nested JSON strings for better display
    final rawJson = widget.note.toJson();
    final displayJson = Map<String, dynamic>.from(rawJson);

    // Decode attachments if it's a string
    if (displayJson['attachments'] is String) {
      try {
        displayJson['attachments'] = json.decode(displayJson['attachments']);
      } catch (_) {
        // Keep as string if decode fails - display will handle it
      }
    }

    // Decode reminder if it's a string
    if (displayJson['reminder'] is String) {
      try {
        displayJson['reminder'] = json.decode(displayJson['reminder']);
      } catch (_) {
        // Keep as string if decode fails - display will handle it
      }
    }

    final noteJson = jsonEncoder.convert(displayJson);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Expanded(child: Text(context.l10n.noteJson)),
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: context.l10n.copyToClipboard,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: noteJson));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.l10n.copiedToClipboard)),
                );
              },
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              noteJson,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.l10n.close),
          ),
        ],
      ),
    );
  }

  void _selectedNotesListener(Object? value) {
    setState(() {
      final selectedNotes = value as List<Note>;
      _selectionMode = selectedNotes.isNotEmpty;
      _isSelected = selectedNotes.any((n) => n.id == widget.note.id);
    });
  }

  Widget _buildSyncIndicator() {
    final icon = Icon(
      _isSyncingOutgoing ? Icons.cloud_upload : Icons.cloud_download,
      size: 14.0,
      color: Theme.of(context).colorScheme.primary,
    );

    if (MediaQuery.disableAnimationsOf(context)) {
      return Transform.rotate(angle: 2 * pi, child: icon);
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 800),
      builder: (context, value, child) {
        return Transform.rotate(angle: value * 2 * pi, child: child);
      },
      onEnd: () {
        if (mounted && (_isSyncingOutgoing || _isSyncingIncoming)) {
          setState(() {}); // Trigger rebuild to restart animation
        }
      },
      child: icon,
    );
  }

  Widget _buildCheckboxProgress(Note note, Color secondaryColor) {
    final checkboxCount = note.checkboxCount;
    final progress = note.checkboxProgress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.checklist, size: 14.0, color: secondaryColor),
            SizedBox(width: 4),
            Text(
              '${checkboxCount.checked}/${checkboxCount.total}',
              style: TextStyle(fontSize: 12, color: secondaryColor),
            ),
          ],
        ),
        SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            backgroundColor: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(
              progress == 1.0
                  ? Colors.green
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }

  /// Gets the color for different reminder types
  Color _getReminderColor(Note note, Color foregroundColor) {
    if (note.completed) {
      return Colors.green; // Completed - green
    }

    final reminder = note.reminder;
    if (reminder == null) return foregroundColor;

    if (note.hasReminderExpired) {
      if (reminder.isRepeating) {
        return Colors.orange; // Expired repeating - orange (will repeat)
      }
      return Colors.red.shade400; // Expired one-time - red
    }

    // Upcoming reminders - color based on repeat type
    return switch (reminder.repeat) {
      Reminder.repeatDaily => Colors.blue.shade400, // Daily - blue
      Reminder.repeatWeekly => Colors.purple.shade400, // Weekly - purple
      Reminder.repeatMonthly => Colors.teal.shade400, // Monthly - teal
      Reminder.repeatYearly => Colors.indigo.shade400, // Yearly - indigo
      _ => foregroundColor, // One-time/Never - default
    };
  }

  /// Builds a styled text span for special words (bold & capitalized)
  TextSpan _buildStyledWord(String word, TextStyle baseStyle) {
    final specialWords = ['daily', 'weekly', 'monthly', 'yearly', 'all day'];
    final lowerWord = word.toLowerCase();

    if (specialWords.contains(lowerWord)) {
      return TextSpan(
        text: word.toUpperCase(),
        style: baseStyle.copyWith(fontWeight: FontWeight.bold),
      );
    }
    return TextSpan(text: word, style: baseStyle);
  }

  Widget _buildReminderLabel(
    Reminder reminder,
    String dateLabel,
    String timeLabel,
    TextStyle baseStyle,
  ) {
    final repeat = reminder.repeat;
    final isRepeating = reminder.isRepeating;

    List<TextSpan> spans = [];

    if (reminder.isAllDay) {
      // All day reminder: <date> ALL DAY <REPEAT?>
      spans.add(TextSpan(text: '$dateLabel ', style: baseStyle));
      spans.add(
        TextSpan(
          text: context.l10n.allDay.toUpperCase(),
          style: baseStyle.copyWith(fontWeight: FontWeight.bold),
        ),
      );
      if (isRepeating) {
        spans.add(TextSpan(text: ' ', style: baseStyle));
        spans.add(_buildStyledWord(repeat, baseStyle));
      }
    } else if (isRepeating) {
      // For repeated reminders: show time and REPEAT type
      spans.add(TextSpan(text: '$timeLabel ', style: baseStyle));
      spans.add(_buildStyledWord(repeat, baseStyle));
    } else {
      // For non-repeated reminders: show date and time
      spans.add(TextSpan(text: '$dateLabel $timeLabel', style: baseStyle));
    }

    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildCard() {
    final note = widget.note;
    final noteColor = note.color == Colors.transparent
        ? Theme.of(context).colorScheme.surface
        : note.color;
    final foregroundColor = isDark(noteColor) ? Colors.white : Colors.black;
    final secondaryColor = foregroundColor.withAlpha(180);
    final noteReminder = note.reminder;
    final reminderDate = noteReminder?.dateTime;
    final reminderLabelDate = reminderDate == null
        ? ''
        : '${weekDaysShort[reminderDate.weekday - 1]} ${reminderDate.day}/${reminderDate.month}/${reminderDate.year}';
    late final String reminderLabelTime;

    final List<String> labels = note.labels != null
        ? note.labels!
              .split(',')
              .map((e) => e.trim())
              .where((label) => label.isNotEmpty)
              .toList()
        : [];
    final time = note.updatedAt ?? note.createdAt ?? DateTime.now();

    if (noteReminder == null) {
      reminderLabelTime = '';
    } else if (noteReminder.isAllDay) {
      reminderLabelTime = '';
    } else {
      // format time to AM/PM
      final hour = reminderDate!.hour;
      final minute = reminderDate.minute;
      final amPm = hour >= 12 ? 'PM' : 'AM';
      final formattedHour = hour % 12 == 0 ? 12 : hour % 12;
      reminderLabelTime =
          '$formattedHour:${minute.toString().padLeft(2, '0')} $amPm';
    }

    // Highlight for active "All Day" reminders
    final isAllDayActive = note.isAllDayReminderActive;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final hasCustomColor = note.color != Colors.transparent;

    // Modern border styling
    final highlightColor = isAllDayActive
        ? Theme.of(context).colorScheme.primary
        : _isSelected
        ? Theme.of(context).colorScheme.primary.withAlpha(180)
        : isDarkMode
        ? Colors.white.withAlpha(25)
        : Colors.black.withAlpha(15);
    final highlightWidth = isAllDayActive ? 2.5 : (_isSelected ? 2.5 : 1.0);

    // Modern card color with subtle surface tint
    final cardColor = hasCustomColor
        ? note.color
        : isDarkMode
        ? Theme.of(context).colorScheme.surfaceContainerHigh
        : Theme.of(context).colorScheme.surfaceContainerLowest;

    return Card(
      margin: const EdgeInsets.all(0),
      clipBehavior: Clip.antiAlias,
      elevation: isDarkMode ? 0 : 0.5,
      shadowColor: Colors.black.withAlpha(isDarkMode ? 0 : 40),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.0),
        side: BorderSide(color: highlightColor, width: highlightWidth),
      ),
      color: cardColor,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(
                bottom: (note.title != null && note.title!.trim().isNotEmpty)
                    ? 12
                    : 0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 4.0,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (kDebugMode) ...[
                        Text(
                          'ID: ${note.id}',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey,
                            fontFamily: 'monospace',
                          ),
                        ),
                        GestureDetector(
                          onTap: _showNoteJson,
                          child: const Icon(
                            Icons.data_object,
                            size: 14.0,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                      if (note.pinned)
                        Icon(Icons.push_pin, size: 14.0, color: secondaryColor),
                      if (_isSyncFailed)
                        Tooltip(
                          message: context.l10n.syncFailed,
                          child: Icon(
                            Icons.sync_problem,
                            size: 14.0,
                            color: Colors.red,
                          ),
                        ),
                      if (_isSyncingOutgoing || _isSyncingIncoming)
                        _buildSyncIndicator(),
                    ],
                  ),
                  if (kDebugMode && _syncStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2.0),
                      child: Text(
                        _syncStatus!,
                        style: TextStyle(
                          fontSize: 9,
                          color: Colors.blue,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.only(
                      top: 8.0,
                      bottom:
                          (note.title != null && note.title!.trim().isNotEmpty)
                          ? 8.0
                          : 0,
                    ),
                    child: Text(
                      "${weekDaysShort[time.weekday - 1]} ${time.day}/${time.month}/${time.year}",
                      style: TextStyle(fontSize: 12, color: secondaryColor),
                    ),
                  ),
                ],
              ),
            ),
            if (note.title != null && note.title!.trim().isNotEmpty) ...[
              Text(
                note.title!.trim(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: foregroundColor,
                ),
              ),
              SizedBox(height: 10),
            ],
            if (note.images.isNotEmpty || note.sketches.isNotEmpty) ...[
              Builder(
                builder: (context) {
                  if (NoteCard.usesPrivateAttachmentPresentation(
                    locked: note.locked,
                    unlocked: note.unlocked,
                  )) {
                    return _buildLockedThumbnailGrid(note);
                  }

                  final grid = NoteImageGrid(
                    // Key ensures grid rebuilds when note is updated (e.g., after sync)
                    key: ValueKey(
                      'note_images_${note.id}_${note.updatedAt?.millisecondsSinceEpoch ?? 0}',
                    ),
                    images: [
                      ...note.images,
                      ...note.sketches.map(
                        (s) => NoteImage(
                          // An empty source is rendered as the neutral
                          // unavailable placeholder by NoteImageGrid.
                          src: s.previewImage ?? '',
                          aspectRatio:
                              "${(s.aspectRatio > 0 ? s.aspectRatio : 1.0) * 1000 ~/ 1}:1000",
                          size: 0,
                          lastModified: DateTime.now().toIso8601String(),
                          index: 0,
                        ),
                      ),
                    ],
                    onImageTap: (_) => _handleTap(),
                    maxHeight: 200,
                    noteId: note.id,
                  );

                  return grid;
                },
              ),
              SizedBox(height: 10),
            ],
            if (_hasDecryptionError)
              Container(
                padding: EdgeInsets.all(10.0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8.0),
                  color: Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.7),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18.0,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    SizedBox(width: 8.0),
                    Flexible(
                      child: Text(
                        context.l10n.decryptionFailed,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else if (note.locked)
              Container(
                padding: EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8.0),
                  color: Colors.grey.withAlpha(50),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      // Show locked icon if forget password setting is enabled
                      (note.unlocked && !AppState.forgetLockedNotePassword)
                          ? Icons.lock_open
                          : Icons.lock,
                      size: 16.0,
                      color: foregroundColor,
                    ),
                    SizedBox(width: 4.0),
                    Flexible(
                      child: Text(
                        context.l10n.thisNoteIsLocked,
                        softWrap: true,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: foregroundColor),
                      ),
                    ),
                  ],
                ),
              )
            else if (_controller != null)
              IgnorePointer(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const scale = 0.8;
                    return SizedBox(
                      width: constraints.maxWidth,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: constraints.maxWidth / scale,
                          child: QuillEditor.basic(
                            controller: _controller!,
                            scrollController: _scrollController,
                            focusNode: _focusNode,
                            config: QuillEditorConfig(
                              customLeadingBlockBuilder:
                                  customLeadingBlockBuilder,
                              customStyles: buildQuillStyles(
                                foregroundColor: foregroundColor,
                                backgroundColor: noteColor,
                                secondaryColor: secondaryColor,
                              ),
                              embedBuilders: kIsWeb
                                  ? FlutterQuillEmbeds.editorWebBuilders()
                                  : FlutterQuillEmbeds.editorBuilders(
                                      imageEmbedConfig: QuillEditorImageEmbedConfig(
                                        imageProviderBuilder: (context, imageUrl) {
                                          if (imageUrl.startsWith('http://') ||
                                              imageUrl.startsWith('https://')) {
                                            return NetworkImage(imageUrl);
                                          } else if (imageUrl.startsWith(
                                            'data:image/',
                                          )) {
                                            // Check cache first
                                            if (_base64ImageCache.containsKey(
                                              imageUrl,
                                            )) {
                                              return _base64ImageCache[imageUrl];
                                            }
                                            try {
                                              final regex = RegExp(
                                                r'^data:image/[^;]+;base64,(.+)$',
                                              );
                                              final match = regex.firstMatch(
                                                imageUrl,
                                              );
                                              if (match != null) {
                                                final base64Data = match.group(
                                                  1,
                                                )!;
                                                final bytes = base64Decode(
                                                  base64Data,
                                                );
                                                final image = MemoryImage(
                                                  bytes,
                                                );
                                                // Cache with size limit
                                                if (_base64ImageCache.length >=
                                                    _maxImageCacheSize) {
                                                  _base64ImageCache.remove(
                                                    _base64ImageCache
                                                        .keys
                                                        .first,
                                                  );
                                                }
                                                _base64ImageCache[imageUrl] =
                                                    image;
                                                return image;
                                              }
                                            } catch (e) {
                                              AppLogger.error(
                                                '[NoteCard] Failed to decode data URL',
                                                e,
                                              );
                                            }
                                          }
                                          return null;
                                        },
                                        imageErrorWidgetBuilder:
                                            (context, error, stackTrace) {
                                              return Container(
                                                padding: const EdgeInsets.all(
                                                  4,
                                                ),
                                                child: Icon(
                                                  Icons.broken_image_outlined,
                                                  size: 14,
                                                  color: Colors.grey,
                                                ),
                                              );
                                            },
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            SizedBox(height: 10),
            NoteCardAudioGroup(
              recordings: note.recordings,
              locked: note.locked,
              foregroundColor: foregroundColor,
            ),
            if (reminderLabelDate.isNotEmpty) ...[
              Builder(
                builder: (context) {
                  final reminderColor = _getReminderColor(
                    note,
                    foregroundColor,
                  );
                  final isRepeating = noteReminder!.isRepeating;
                  final isExpiredRepeating =
                      note.hasReminderExpired && isRepeating && !note.completed;

                  return TextButton.icon(
                    onPressed: _selectionMode
                        ? null
                        : () async {
                            final newReminder = await reminder(
                              context,
                              initialReminder: note.reminder,
                            );

                            if (newReminder == null) {
                              return;
                            }

                            await note.setReminder(newReminder);
                            if (mounted) {
                              _lastReminder = note.reminder;
                              _scheduleReminderExpiration();
                              setState(() {});
                            }
                          },
                    style: ButtonStyle(
                      padding: WidgetStatePropertyAll<EdgeInsets>(
                        EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                      ),
                      backgroundColor: WidgetStatePropertyAll<Color>(
                        reminderColor.withAlpha(25),
                      ),
                      foregroundColor: WidgetStatePropertyAll<Color>(
                        reminderColor,
                      ),
                      shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8.0),
                        ),
                      ),
                    ),
                    icon: IconTransitionAnimation(
                      fromIcon: noteReminder.type == ReminderType.alarm
                          ? Icons.alarm
                          : Icons.notifications,
                      toIcon: note.completed
                          ? Icons.done
                          : isExpiredRepeating
                          ? Icons
                                .update // Animated icon for expired repeating
                          : note.hasReminderExpired
                          ? noteReminder.type == ReminderType.alarm
                                ? Icons.alarm_off
                                : Icons.notifications_off
                          : noteReminder.type == ReminderType.alarm
                          ? Icons.alarm
                          : Icons.notifications,
                      duration: Duration(milliseconds: 1000),
                      repeat: true,
                      size: 14.0,
                      color: reminderColor,
                    ),
                    label: _buildReminderLabel(
                      noteReminder,
                      reminderLabelDate,
                      reminderLabelTime,
                      TextStyle(fontSize: 12, color: reminderColor),
                    ),
                  );
                },
              ),
              SizedBox(height: 10),
            ],
            Wrap(
              spacing: 4.0,
              runSpacing: 4.0,
              children: labels
                  .map(
                    (label) => Container(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: foregroundColor.withAlpha(80),
                        ),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12.0,
                          color: foregroundColor,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            if (note.hasCheckboxes) ...[
              SizedBox(height: 10),
              _buildCheckboxProgress(note, secondaryColor),
            ],
            if (AppState.showNotes == NoteType.reminder && note.hasReminder)
              _ReminderCardActions(
                showDone: !note.reminder!.isRepeating && !note.completed,
                foregroundColor: foregroundColor,
                onDone: () => _handleReminderDone(note),
                onRemove: () async {
                  try {
                    await _handleRemoveReminder(note);
                  } catch (e) {
                    snackbar(
                      'Failed to remove reminder: $e',
                      Colors.red.shade400,
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleRemoveReminder(Note note) async {
    final message = context.l10n.reminderRemoved;
    await note.deleteReminder();
    snackbar(message, Colors.green);
    if (mounted) {
      setState(() {});
    }
  }

  void _toggleSelection() {
    HapticFeedback.selectionClick();
    if (_isSelected) {
      AppState.selectedNotes = AppState.selectedNotes
          .where((n) => n.id != widget.note.id)
          .toList();
      setState(() {
        _isSelected = false;
      });
    } else {
      AppState.selectedNotes = List.from(AppState.selectedNotes)
        ..add(widget.note);
      setState(() {
        _isSelected = true;
      });
    }
  }

  Future<void> _handleReminderDone(Note note) async {
    // Only for non-repeating reminders
    snackbar(context.l10n.reminderCompleted, Colors.green);
    await note.done();

    if (mounted) {
      setState(() {});
    }
  }

  /// Builds a grid of blurred thumbnails for locked notes.
  /// Uses the same NoteImageGrid layout as unlocked notes to prevent size changes.
  /// Thumbnails are pre-generated tiny images (<1KB) that are safe to display
  /// even when note is locked - they're too low-res to reveal content.
  Widget _buildLockedThumbnailGrid(Note note) {
    final images = NoteCard.privateAttachmentPresentations(note);

    // Check if any thumbnails are available
    final hasThumbnails = images.any((img) => img.blurredThumbnail != null);

    if (!hasThumbnails) {
      // No thumbnails available - show placeholder grid instead of trying to
      // load encrypted files which would fail
      return _buildLockedPlaceholderGrid(images.length);
    }

    // Use NoteImageGrid with custom thumbnail builder for exact layout match
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
      child: NoteImageGrid(
        images: images,
        onImageTap: (_) => _handleTap(),
        maxHeight: 200,
        noteId: null, // No hero animation for locked thumbnails
        customImageBuilder: _buildThumbnailTile,
      ),
    );
  }

  /// Builds a placeholder grid for locked notes without thumbnails.
  Widget _buildLockedPlaceholderGrid(int count) {
    if (count == 0) return const SizedBox.shrink();

    return Container(
      height: 100,
      padding: const EdgeInsets.all(8),
      child: Row(
        children: List.generate(
          count.clamp(1, 3),
          (index) => Expanded(
            child: Container(
              margin: EdgeInsets.only(
                right: index < count.clamp(1, 3) - 1 ? 4 : 0,
              ),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Icon(Icons.image, color: Colors.grey.shade500, size: 32),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a thumbnail tile for the locked note grid.
  Widget _buildThumbnailTile(
    NoteImage image,
    int index,
    int total,
    BoxFit fit,
  ) {
    final thumbnailBytes = ThumbnailGenerator.decodeFromBase64(
      image.blurredThumbnail,
    );

    if (thumbnailBytes == null) {
      // Fallback to grey placeholder if no thumbnail
      return Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }

    final cacheKey = 'thumb_${image.blurredThumbnail.hashCode}';
    if (!_base64ImageCache.containsKey(cacheKey)) {
      // Evict oldest entries if cache is full
      if (_base64ImageCache.length >= _maxImageCacheSize) {
        _base64ImageCache.remove(_base64ImageCache.keys.first);
      }
      _base64ImageCache[cacheKey] = MemoryImage(thumbnailBytes);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox.expand(
        child: Image(
          image: _base64ImageCache[cacheKey]!,
          fit: fit,
          gaplessPlayback: true,
        ),
      ),
    );
  }
}
