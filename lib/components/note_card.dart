import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:better_keep/components/animated_icon.dart';
import 'package:better_keep/components/note_image_grid.dart';
import 'package:better_keep/dialogs/unlock_note_dialog.dart';
import 'package:better_keep/dialogs/reminder.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/attachments/image_attachment.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/services/sync/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/show_page.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:better_keep/utils/week_days.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill_extensions/flutter_quill_extensions.dart';

class NoteCard extends StatefulWidget {
  final Note note;
  final int index;

  const NoteCard({super.key, required this.note, required this.index});

  @override
  State<NoteCard> createState() => _NoteCardState();
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
  QuillController? _controller;
  Timer? _noteReminderExpiration;

  late final AnimationController _anim;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  final _focusNode = FocusNode(canRequestFocus: false);
  final _scrollController = ScrollController();

  String? _lastContent;
  Reminder? _lastReminder;
  int _lastMaxChars = 500;

  /// Returns max chars based on screen width (1000 for bigger screens, 500 for smaller)
  int _getMaxChars(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return screenWidth > 600 ? 1000 : 500;
  }

  /// Creates a truncated document limited to maxChars characters
  Document? _createTruncatedDocument(Document? doc, {int maxChars = 500}) {
    if (doc == null) return null;

    final plainText = doc.toPlainText();
    if (plainText.length <= maxChars) return doc;

    // Truncate at maxChars and add ellipsis
    final truncatedText = '${plainText.substring(0, maxChars)}...';
    return Document()..insert(0, truncatedText);
  }

  @override
  void initState() {
    final selectedNotes = AppState.selectedNotes;
    final doc = widget.note.document;
    final note = widget.note;

    _lastContent = note.content;
    _lastReminder = note.reminder;

    // Listen for sync state changes
    NoteSyncService().syncingOutgoing.addListener(_onSyncStateChanged);
    NoteSyncService().syncingIncoming.addListener(_onSyncStateChanged);
    NoteSyncService().syncFailed.addListener(_onSyncStateChanged);
    NoteSyncService().noteStatus.addListener(_onSyncStateChanged);
    _updateSyncState();

    if (note.hasReminder && !note.hasReminderExpired) {
      _noteReminderExpiration = Timer(
        note.reminder!.dateTime.difference(DateTime.now()),
        () {
          if (mounted) {
            setState(() {});
          }
        },
      );
    }

    if (!note.locked && doc != null) {
      _controller = QuillController(
        readOnly: true,
        document: _createTruncatedDocument(doc) ?? doc,
        selection: const TextSelection.collapsed(offset: 0),
      );
    }

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

    bool contentChanged = widget.note.content != _lastContent;
    bool reminderChanged = widget.note.reminder != _lastReminder;

    if (widget.note != oldWidget.note || contentChanged) {
      _lastContent = widget.note.content;
      // Update controller if note content changed
      final doc = widget.note.document;
      if (!widget.note.locked && doc != null) {
        final truncatedDoc = _createTruncatedDocument(doc) ?? doc;
        if (_controller == null) {
          _controller = QuillController(
            readOnly: true,
            document: truncatedDoc,
            selection: const TextSelection.collapsed(offset: 0),
          );
        } else {
          _controller!.document = truncatedDoc;
        }
      }
    }

    // Update reminder timer if needed
    if (widget.note != oldWidget.note || reminderChanged) {
      _lastReminder = widget.note.reminder;
      _noteReminderExpiration?.cancel();
      if (widget.note.hasReminder && !widget.note.hasReminderExpired) {
        _noteReminderExpiration = Timer(
          widget.note.reminder!.dateTime.difference(DateTime.now()),
          () {
            if (mounted) {
              setState(() {});
            }
          },
        );
      }
    }
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
    _controller?.dispose();
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

    if (widget.note.locked && !widget.note.unlocked) {
      final unlocked = await showUnlockNoteDialog(context, widget.note);
      if (unlocked != true) {
        return;
      }
    }

    if (mounted) {
      showPage(context, NoteEditor(note: widget.note));
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
            const Expanded(child: Text('Note JSON')),
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy to clipboard',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: noteJson));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
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
            child: const Text('Close'),
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
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 800),
      builder: (context, value, child) {
        return Transform.rotate(angle: value * 2 * 3.14159, child: child);
      },
      onEnd: () {
        if (mounted && (_isSyncingOutgoing || _isSyncingIncoming)) {
          setState(() {}); // Trigger rebuild to restart animation
        }
      },
      child: Icon(
        _isSyncingOutgoing ? Icons.cloud_upload : Icons.cloud_download,
        size: 14.0,
        color: Theme.of(context).colorScheme.primary,
      ),
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
      spans.add(_buildStyledWord('All Day', baseStyle));
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
      reminderLabelTime = 'All day';
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
              padding: const EdgeInsets.only(bottom: 12),
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
                          message: 'Sync failed',
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
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Text(
                      "${weekDaysShort[time.weekday - 1]} ${time.day}/${time.month}/${time.year}",
                      style: TextStyle(fontSize: 12, color: secondaryColor),
                    ),
                  ),
                ],
              ),
            ),
            if (note.title != null && note.title!.isNotEmpty) ...[
              Text(
                note.title!,
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
                  final grid = NoteImageGrid(
                    images: [
                      ...note.images,
                      ...note.sketches.map(
                        (s) => ImageAttachment(
                          dimension: s.pageDimension,
                          lastModified: DateTime.now().toIso8601String(),
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
            if (note.locked)
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
                      note.unlocked ? Icons.lock_open : Icons.lock,
                      size: 16.0,
                      color: foregroundColor,
                    ),
                    SizedBox(width: 4.0),
                    Flexible(
                      child: Text(
                        "This note is locked",
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
                              customStyles: DefaultStyles(
                                // Default text color based on note background
                                color: foregroundColor,
                                paragraph: DefaultTextBlockStyle(
                                  TextStyle(
                                    fontSize: 16,
                                    color: foregroundColor,
                                  ),
                                  HorizontalSpacing.zero,
                                  VerticalSpacing.zero,
                                  VerticalSpacing.zero,
                                  null,
                                ),
                                h1: DefaultTextBlockStyle(
                                  TextStyle(
                                    fontSize: 28,
                                    color: foregroundColor,
                                  ),
                                  HorizontalSpacing.zero,
                                  VerticalSpacing(0, 10),
                                  VerticalSpacing.zero,
                                  null,
                                ),
                                h2: DefaultTextBlockStyle(
                                  TextStyle(
                                    fontSize: 24,
                                    color: foregroundColor,
                                  ),
                                  HorizontalSpacing.zero,
                                  VerticalSpacing.zero,
                                  VerticalSpacing.zero,
                                  null,
                                ),
                                h3: DefaultTextBlockStyle(
                                  TextStyle(
                                    fontSize: 20,
                                    color: foregroundColor,
                                  ),
                                  HorizontalSpacing.zero,
                                  VerticalSpacing.zero,
                                  VerticalSpacing.zero,
                                  null,
                                ),
                                quote: DefaultTextBlockStyle(
                                  TextStyle(color: secondaryColor),
                                  HorizontalSpacing.zero,
                                  VerticalSpacing(4, 4),
                                  VerticalSpacing.zero,
                                  BoxDecoration(
                                    border: Border(
                                      left: BorderSide(
                                        color: secondaryColor,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                ),
                                lists: DefaultListBlockStyle(
                                  TextStyle(
                                    fontSize: 16,
                                    color: foregroundColor,
                                  ),
                                  HorizontalSpacing.zero,
                                  VerticalSpacing.zero,
                                  VerticalSpacing.zero,
                                  null,
                                  null,
                                ),
                                code: DefaultTextBlockStyle(
                                  TextStyle(
                                    fontSize: 14,
                                    color: foregroundColor,
                                    fontFamily: 'monospace',
                                  ),
                                  HorizontalSpacing.zero,
                                  VerticalSpacing.zero,
                                  VerticalSpacing.zero,
                                  BoxDecoration(
                                    color: isDark(noteColor)
                                        ? Colors.white.withAlpha(20)
                                        : Colors.black.withAlpha(15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                inlineCode: InlineCodeStyle(
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: foregroundColor,
                                    fontFamily: 'monospace',
                                  ),
                                  backgroundColor: isDark(noteColor)
                                      ? Colors.white.withAlpha(20)
                                      : Colors.black.withAlpha(15),
                                  radius: const Radius.circular(4),
                                ),
                                // Inline styles with proper foreground color
                                bold: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: foregroundColor,
                                ),
                                italic: TextStyle(
                                  fontStyle: FontStyle.italic,
                                  color: foregroundColor,
                                ),
                                underline: TextStyle(
                                  decoration: TextDecoration.underline,
                                  decorationColor: foregroundColor,
                                  color: foregroundColor,
                                ),
                                strikeThrough: TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                  decorationColor: foregroundColor,
                                  color: foregroundColor,
                                ),
                                link: TextStyle(
                                  color: isDark(noteColor)
                                      ? Colors.lightBlueAccent
                                      : Colors.blue,
                                  decoration: TextDecoration.underline,
                                ),
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
            ...note.recordings.map(
              (recording) => Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: foregroundColor.withAlpha(50)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.play_circle_outline,
                      size: 16,
                      color: foregroundColor,
                    ),
                    SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        recording.title ?? "Audio",
                        style: TextStyle(fontSize: 12, color: foregroundColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
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
                            final newReminder = await reminder(context);

                            if (newReminder == null) {
                              return;
                            }

                            note.setReminder(newReminder);
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
                      fromIcon: Icons.notifications,
                      toIcon: note.completed
                          ? Icons.done
                          : isExpiredRepeating
                          ? Icons
                                .update // Animated icon for expired repeating
                          : note.hasReminderExpired
                          ? Icons.notifications_off
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
              Center(
                child: Wrap(
                  spacing: 8.0,
                  children: [
                    // Show "Done" button only for non-repeating reminders that are not completed
                    if (!note.reminder!.isRepeating && !note.completed)
                      TextButton.icon(
                        label: Text('Done'),
                        icon: Icon(Icons.done),
                        style: ButtonStyle(
                          foregroundColor: WidgetStatePropertyAll<Color>(
                            foregroundColor,
                          ),
                        ),
                        onPressed: () async {
                          await _handleReminderDone(note);
                        },
                      ),
                    // Always show "Remove Reminder" button
                    TextButton.icon(
                      label: Text('Remove'),
                      icon: Icon(Icons.notifications_off_outlined),
                      style: ButtonStyle(
                        foregroundColor: WidgetStatePropertyAll<Color>(
                          Colors.red.shade400,
                        ),
                      ),
                      onPressed: () async {
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
          ],
        ),
      ),
    );
  }

  Future<void> _handleRemoveReminder(Note note) async {
    await note.deleteReminder();
    snackbar('Reminder removed', Colors.green);
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
    snackbar('Reminder completed', Colors.green);
    await note.done();

    if (mounted) {
      setState(() {});
    }
  }
}
