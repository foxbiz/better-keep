import 'dart:convert';
import 'dart:io';
import 'package:better_keep/components/bubble_menu.dart';
import 'package:better_keep/components/logo.dart';
import 'package:better_keep/dialogs/audio_recorder_dialog.dart';
import 'package:better_keep/dialogs/share_note_dialog.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/components/sync_progress_widget.dart';
import 'package:better_keep/components/user_avatar.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/models/note_image.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/models/sketch.dart';
import 'package:better_keep/pages/setup_recovery_key_page.dart';
import 'package:better_keep/pages/sketch_page.dart';
import 'package:better_keep/services/app_install_service.dart';
import 'package:better_keep/services/camera_detection.dart';
import 'package:better_keep/services/camera_capture.dart';
import 'package:better_keep/services/e2ee/e2ee_service.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:better_keep/components/animated_icon.dart';
import 'package:better_keep/dialogs/delete_dialog.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/home/notes.dart';
import 'package:better_keep/pages/home/sidebar.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/pages/user_page.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with TickerProviderStateMixin {
  late bool _isBigScreen;
  late bool _selectionMode;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  bool _shouldAnimateIcon = false;
  bool _searchMode = false;
  bool _shrinkDrawer = false;
  bool _hasPendingApprovals = false;
  bool _isBubbleMenuOpen = false;

  bool get _selectedNotesPinned {
    return !AppState.selectedNotes.any((note) => !note.pinned);
  }

  set _selectedNotesPinned(bool val) {
    for (final note in AppState.selectedNotes) {
      note.pinned = val;
      note.save();
    }
    AppState.selectedNotes = [];
  }

  set _selectedNotesArchived(bool val) {
    for (final note in AppState.selectedNotes) {
      note.archived = val;
      note.save();
    }
    AppState.selectedNotes = [];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isBigScreen = MediaQuery.of(context).size.width >= bigScreenWidthThreshold;
  }

  @override
  void initState() {
    _selectionMode = AppState.selectedNotes.isNotEmpty;

    _searchFocusNode.addListener(() {
      setState(() {
        _shouldAnimateIcon = true;
        _searchMode = _searchFocusNode.hasFocus;
      });
    });

    _searchController.addListener(() {
      setState(() {});
    });

    AppState.subscribe("show_notes", _showNotesListener);
    AppState.subscribe("selected_notes", _selectedNotesListener);

    // Listen for pending device approvals
    E2EEService.instance.deviceManager.pendingApprovals.addListener(
      _onPendingApprovalsChanged,
    );
    _checkPendingApprovals();

    // Listen for recovery key setup needed (after fresh E2EE setup)
    E2EEService.instance.needsRecoveryKeySetup.addListener(
      _onRecoveryKeySetupNeeded,
    );
    // Check if recovery key setup is already needed
    _checkRecoveryKeySetup();

    // Trigger sync when Home is first shown (fallback for post-approval sync)
    // This ensures notes load even if the E2EE status change listener missed the trigger
    _ensureSyncOnInit();

    // Check if we should show install prompt (first time on web)
    _checkInstallPrompt();

    super.initState();
  }

  /// Check and show install prompt for first-time web users
  void _checkInstallPrompt() {
    if (!kIsWeb) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final info = AppInstallService.instance.getInstallInfo();
      if (info == null) return;

      if (info.shouldShowInstallPrompt) {
        AppInstallService.instance.markPromptShown();
        _showInstallPromptDialog(info);
      }
    });
  }

  /// Show install prompt dialog based on platform
  void _showInstallPromptDialog(AppInstallInfo info) {
    showDialog(
      context: context,
      builder: (context) {
        IconData icon;
        String title;
        String message;
        String actionLabel;
        VoidCallback? onAction;

        if (info.isIOS) {
          icon = Icons.apple;
          title = 'iOS App Coming Soon!';
          message =
              'Our iOS app is being reviewed by Apple. In the meantime, you can install Better Keep as a web app for quick access.\n\nTap Share → Add to Home Screen in Safari.';
          actionLabel = 'Got it';
          onAction = () => Navigator.pop(context);
        } else if (info.isAndroid) {
          icon = Icons.android;
          title = 'Get the Android App';
          message =
              'Better Keep is available on Google Play! Get the native app for the best experience with notifications, widgets, and more.';
          actionLabel = 'Open Play Store';
          onAction = () {
            Navigator.pop(context);
            launchUrl(
              Uri.parse(playStoreUrl),
              mode: LaunchMode.externalApplication,
            );
          };
        } else if (info.isWindows) {
          icon = Icons.desktop_windows;
          title = 'Get the Windows App';
          message =
              'Better Keep is available on Microsoft Store! Get the native app for the best experience with system integration and offline access.';
          actionLabel = 'Open Microsoft Store';
          onAction = () {
            Navigator.pop(context);
            launchUrl(
              Uri.parse(microsoftStoreUrl),
              mode: LaunchMode.externalApplication,
            );
          };
        } else if (info.canInstallPWA) {
          icon = Icons.install_desktop;
          title = 'Install Better Keep';
          message =
              'Install Better Keep for quick access from your home screen and offline support!';
          actionLabel = 'Install';
          onAction = () async {
            Navigator.pop(context);
            await AppInstallService.instance.triggerPWAInstall();
          };
        } else {
          return const SizedBox.shrink();
        }

        return AlertDialog(
          icon: Icon(
            icon,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                AppInstallService.instance.markPromptDismissed();
                Navigator.pop(context);
              },
              child: const Text('Not now'),
            ),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        );
      },
    );
  }

  /// Ensures sync is triggered when Home is first shown with E2EE ready.
  /// This is a fallback for when the status change listener doesn't trigger sync
  /// (e.g., after device approval).
  void _ensureSyncOnInit() {
    // Only trigger if E2EE is ready and we're not already syncing
    if (E2EEService.instance.isReady && !NoteSyncService().isSyncing.value) {
      // Use post-frame callback to avoid blocking widget build
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && E2EEService.instance.isReady) {
          NoteSyncService().refresh();
        }
      });
    }
  }

  void _onPendingApprovalsChanged() {
    _checkPendingApprovals();
  }

  Future<void> _checkPendingApprovals() async {
    final pendingApprovals =
        E2EEService.instance.deviceManager.pendingApprovals.value;
    final isFirst = await E2EEService.instance.deviceManager.isFirstDevice();

    if (mounted) {
      setState(() {
        _hasPendingApprovals = pendingApprovals.isNotEmpty && isFirst;
      });
    }
  }

  void _onRecoveryKeySetupNeeded() {
    if (E2EEService.instance.needsRecoveryKeySetup.value) {
      _checkRecoveryKeySetup();
    }
  }

  Future<void> _checkRecoveryKeySetup() async {
    // Use post-frame callback to show dialog after widget is built
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (E2EEService.instance.needsRecoveryKeySetup.value) {
        // Reset the flag
        E2EEService.instance.needsRecoveryKeySetup.value = false;

        // Show recovery key setup page
        if (mounted) {
          final result = await showSetupRecoveryKeyPage(context);
          if (result == true && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Recovery key saved successfully!'),
                backgroundColor: Colors.green,
              ),
            );
          } else if (result == false && mounted) {
            // Show a more prominent warning dialog for skipped recovery key
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                icon: const Icon(
                  Icons.warning_amber,
                  color: Colors.orange,
                  size: 48,
                ),
                title: const Text('No Recovery Key'),
                content: const Text(
                  'Without a recovery key, you will permanently lose access to all your encrypted notes if you lose all your devices.\n\n'
                  'Consider setting up a recovery key later in Settings.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('I understand'),
                  ),
                ],
              ),
            );
          }
        }
      }
    });
  }

  @override
  void dispose() {
    AppState.unsubscribe("show_notes", _showNotesListener);
    AppState.unsubscribe("selected_notes", _selectedNotesListener);
    E2EEService.instance.deviceManager.pendingApprovals.removeListener(
      _onPendingApprovalsChanged,
    );
    E2EEService.instance.needsRecoveryKeySetup.removeListener(
      _onRecoveryKeySetupNeeded,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_searchMode && !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }

        if (_selectionMode) {
          AppState.selectedNotes = [];
          return;
        }

        _searchFocusNode.unfocus();
        setState(() {
          _searchMode = false;
        });
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 60,
          automaticallyImplyLeading: false,
          titleSpacing: _searchMode && !_isBigScreen ? 0 : null,
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (_isBigScreen) ...[const Logo(), const SizedBox(width: 24)],
              Expanded(child: _buildTitle()),
            ],
          ),
          leading: _buildLeading(),
          actions: _buildActions(),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4.0),
            child: ValueListenableBuilder<bool>(
              valueListenable: NoteSyncService().isSyncing,
              builder: (context, isSyncing, child) {
                if (isSyncing) {
                  return const LinearProgressIndicator();
                }
                return const SizedBox(height: 4.0);
              },
            ),
          ),
        ),
        drawer: _isBigScreen
            ? null
            : Drawer(
                shape: ShapeBorder.lerp(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.only(
                      topRight: Radius.zero,
                      bottomRight: Radius.zero,
                    ),
                  ),
                  RoundedRectangleBorder(),
                  1.0,
                )!,
                child: Sidebar(),
              ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            return SizedBox(
              height: constraints.maxHeight,
              child: Stack(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_isBigScreen)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: _shrinkDrawer ? 80 : 240,
                          child: Sidebar(shrink: _shrinkDrawer),
                        ),
                      Expanded(
                        child: Notes(
                          searchMode: _searchMode,
                          searchQuery: _searchController.text,
                        ),
                      ),
                    ],
                  ),
                  // Dim overlay when bubble menu is open
                  if (_isBubbleMenuOpen)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          opacity: _isBubbleMenuOpen ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Container(
                            color: Colors.black.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                    ),
                  const SyncProgressWidget(),
                  // FAB with opacity/scale animation
                  Positioned(
                    right: 24,
                    bottom:
                        8 +
                        MediaQuery.of(context).padding.bottom +
                        // Extra margin for non-mobile platforms
                        (kIsWeb ||
                                (!kIsWeb &&
                                    (Platform.isWindows ||
                                        Platform.isMacOS ||
                                        Platform.isLinux))
                            ? 16
                            : 0),
                    child: AnimatedOpacity(
                      opacity:
                          _selectionMode ||
                              AppState.showNotes != NoteType.all ||
                              _searchMode
                          ? 0.0
                          : 1.0,
                      duration: const Duration(milliseconds: 200),
                      child: AnimatedScale(
                        scale:
                            _selectionMode ||
                                AppState.showNotes != NoteType.all ||
                                _searchMode
                            ? 0.0
                            : 1.0,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutBack,
                        child: IgnorePointer(
                          ignoring:
                              _selectionMode ||
                              AppState.showNotes != NoteType.all ||
                              _searchMode,
                          child: _buildBubbleMenu(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _showNotesListener(dynamic payload) async {
    setState(() {});
  }

  void _selectedNotesListener(dynamic notes) {
    setState(() {
      _selectionMode = (notes as List).isNotEmpty;
      _shouldAnimateIcon = true;
    });
  }

  Widget? _buildLeading() {
    if (_searchMode && !_isBigScreen) {
      return null;
    }

    if (_selectionMode) {
      // Hide leading entirely on big screens
      if (_isBigScreen) {
        return null;
      }
      return IconButton(
        onPressed: () {
          AppState.selectedNotes = [];
        },
        icon: AnimatedMenuIcon(icon: AnimatedIcons.menu_close),
      );
    }

    return Builder(
      builder: (context) => IconButton(
        onPressed: () {
          if (_isBigScreen) {
            setState(() {
              _shrinkDrawer = !_shrinkDrawer;
            });
          } else {
            Scaffold.of(context).openDrawer();
          }
        },
        icon: _shouldAnimateIcon
            ? AnimatedMenuIcon(icon: AnimatedIcons.close_menu)
            : AnimatedMenuIcon(
                icon: AnimatedIcons.home_menu,
                duration: Duration(seconds: 3),
                curve: Curves.easeIn,
              ),
      ),
    );
  }

  Widget _buildTitle() {
    if (_selectionMode) {
      final count = AppState.selectedNotes.length;
      if (_isBigScreen) {
        // On big screen: show close icon + count as title
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: () {
                AppState.selectedNotes = [];
              },
              icon: const Icon(Icons.close),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 12),
            Text("$count"),
          ],
        );
      }
      // On small screen: just show count (close icon is in leading)
      return Text("$count");
    }

    if (AppState.showNotes == NoteType.all) {
      return _buildSearchField();
    } else if (_isBigScreen) {
      return Text("");
    }

    if (AppState.showNotes == NoteType.archived) {
      return Text("Archive");
    }

    if (AppState.showNotes == NoteType.trashed) {
      return Text("Trash");
    }

    if (AppState.showNotes == NoteType.reminder) {
      return Text("Reminders");
    }

    return Text(appLabel);
  }

  List<Widget> _buildActions() {
    if (_selectionMode) {
      return _buildSelectionActions();
    }

    if (_searchMode && !_isBigScreen) {
      return [];
    }

    if ([NoteType.archived, NoteType.reminder].contains(AppState.showNotes)) {
      return [];
    }

    bool showRefresh = false;
    if (kIsWeb || Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // if is touch device, don't show refresh button
      showRefresh =
          !MediaQuery.of(context).size.shortestSide.isFinite ||
          MediaQuery.of(context).size.shortestSide > 600;
    }

    if (AppState.showNotes == NoteType.trashed) {
      return [
        if (showRefresh)
          IconButton(
            onPressed: () {
              NoteSyncService().refresh();
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        IconButton(
          onPressed: () async {
            final confirmation = await showDeleteDialog(
              context,
              title: "Delete Forever",
              message:
                  "Do you really want to delete all notes in the trash forever, this can't be undone.",
            );

            if (confirmation != true) {
              return;
            }

            final notesToDelete = await Note.get(NoteType.trashed);

            for (final note in notesToDelete) {
              await note.delete();
            }
          },
          icon: Icon(Icons.delete_forever),
        ),
      ];
    }

    return [
      if (showRefresh)
        IconButton(
          onPressed: () {
            NoteSyncService().refresh();
          },
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
        ),
      Container(
        margin: const EdgeInsets.symmetric(horizontal: 8.0),
        child: GestureDetector(
          onTap: () {
            showPage(context, const UserPage());
          },
          child: UserAvatar(
            size: 20,
            heroTag: 'user_avatar',
            showPendingBadge: _hasPendingApprovals,
            showProBorder: true,
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildSelectionActions() {
    if (AppState.showNotes == NoteType.trashed) {
      return [
        IconButton(
          onPressed: () {
            for (final note in AppState.selectedNotes) {
              note.restoreFromTrash();
            }
            AppState.selectedNotes = [];
          },
          icon: Icon(Icons.restore),
        ),
        IconButton(
          onPressed: () async {
            final confirmation = await showDeleteDialog(
              context,
              title: "Delete Forever",
              message:
                  "Do you really want to delete ${AppState.selectedNotes.length} notes forever, this can't be undone.",
            );

            if (confirmation != true) {
              return;
            }

            for (final note in AppState.selectedNotes) {
              await note.delete();
            }

            AppState.selectedNotes = [];
          },
          icon: Icon(Icons.delete_forever),
        ),
      ];
    }

    if (AppState.showNotes == NoteType.all) {
      return [
        // Share button - only show when exactly 1 note is selected
        if (AppState.selectedNotes.length == 1)
          IconButton(
            onPressed: () {
              final note = AppState.selectedNotes.first;
              showShareNoteDialog(context, note);
            },
            icon: const Icon(Icons.share),
            tooltip: 'Share',
          ),
        IconButton(
          onPressed: () {
            _selectedNotesPinned = !_selectedNotesPinned;
          },
          icon: Icon(
            _selectedNotesPinned ? Icons.push_pin : Icons.push_pin_outlined,
          ),
        ),
        IconButton(
          onPressed: () {
            _selectedNotesArchived = true;
          },
          icon: Icon(Icons.archive),
        ),
        IconButton(
          onPressed: () {
            for (final note in AppState.selectedNotes) {
              note.moveToTrash();
            }
            AppState.selectedNotes = [];
          },
          icon: Icon(Icons.delete),
        ),
      ];
    }

    if (AppState.showNotes == NoteType.archived) {
      return [
        IconButton(
          onPressed: () {
            _selectedNotesArchived = false;
          },
          icon: Icon(Icons.unarchive),
        ),
        IconButton(
          onPressed: () {
            for (final note in AppState.selectedNotes) {
              note.moveToTrash();
            }
            AppState.selectedNotes = [];
          },
          icon: Icon(Icons.delete),
        ),
      ];
    }

    return [];
  }

  Widget _buildSearchField() {
    late String hintText;
    late BorderRadius borderRadius;
    BorderSide borderSide = BorderSide.none;
    BorderSide enabledBorderSide = BorderSide.none;
    BorderSide focusedBorderSide = BorderSide.none;

    if (_searchMode || _isBigScreen) {
      hintText = 'Search';
    } else {
      hintText = appLabel;
    }

    if (_isBigScreen) {
      borderSide = BorderSide(color: Theme.of(context).colorScheme.outline);
      enabledBorderSide = BorderSide(
        color: Theme.of(context).colorScheme.outline,
      );
      focusedBorderSide = BorderSide(
        color: Theme.of(context).colorScheme.primary,
        width: 2.0,
      );
    }

    if (_isBigScreen) {
      borderRadius = BorderRadius.circular(8);
    } else if (_searchMode) {
      borderRadius = BorderRadius.zero;
    } else {
      borderRadius = BorderRadius.circular(100);
    }

    return AnimatedAlign(
      alignment: Alignment.center,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: BoxConstraints(maxWidth: _searchMode ? 460 : 400),
        child: TextField(
          focusNode: _searchFocusNode,
          controller: _searchController,
          decoration: InputDecoration(
            filled: true,
            prefixIcon: _searchMode || _isBigScreen
                ? const Icon(Icons.search)
                : Padding(
                    padding: const EdgeInsets.only(left: 12, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.asset(
                            'assets/better_keep-512.png',
                            width: 28,
                            height: 28,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          appLabel,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 18,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
            prefixIconConstraints: _searchMode || _isBigScreen
                ? null
                : const BoxConstraints(minWidth: 0, minHeight: 0),
            hintText: _searchMode || _isBigScreen ? hintText : null,
            hintStyle: _searchMode
                ? null
                : const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
            contentPadding: const EdgeInsets.symmetric(
              vertical: 0,
              horizontal: 16,
            ),
            border: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: borderSide,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: enabledBorderSide,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: borderRadius,
              borderSide: focusedBorderSide,
            ),
            suffixIcon: _searchMode
                ? IconButton(
                    icon: Icon(Icons.clear),
                    onPressed: () {
                      _searchController.clear();
                      _searchFocusNode.unfocus();
                    },
                  )
                : null,
          ),
        ),
      ),
    );
  }

  Widget _buildBubbleMenu() {
    return BubbleMenu(
      fabIcon: Icons.add,
      fabSize: 64,
      itemDistance: 110,
      itemSize: 56,
      onMenuStateChanged: (isOpen) {
        setState(() {
          _isBubbleMenuOpen = isOpen;
        });
      },
      onDefaultAction: () {
        // Default action: open new note
        showPage(context, NoteEditor());
      },
      items: [
        BubbleMenuItem(
          icon: Icons.image,
          label: 'Image',
          onTap: () => _createImageNote(),
        ),
        BubbleMenuItem(
          icon: Icons.mic,
          label: 'Audio',
          onTap: () => _createAudioNote(),
        ),
        BubbleMenuItem(
          icon: Icons.draw,
          label: 'Sketch',
          onTap: () => _createSketchNote(),
        ),
        BubbleMenuItem(
          icon: Icons.check_box_outlined,
          label: 'Todo',
          onTap: () => _createTodoNote(),
        ),
      ],
    );
  }

  /// Create a new sketch note
  void _createSketchNote() {
    final note = Note(content: '');
    showPage(
      context,
      SketchPage(
        note: note,
        sketch: SketchData(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
    );
  }

  /// Create a new audio note with recording
  Future<void> _createAudioNote() async {
    final result = await showDialog<AudioRecordingResult>(
      context: context,
      builder: (context) => const AudioRecorderDialog(),
    );

    if (result != null && mounted) {
      // Create note with title from transcription or "Audio Note"
      String? title;
      if (result.transcription != null && result.transcription!.isNotEmpty) {
        final words = result.transcription!
            .split(' ')
            .where((w) => w.isNotEmpty)
            .toList();
        if (words.isNotEmpty) {
          title = words.take(5).join(' ') + (words.length > 5 ? '...' : '');
        }
      }
      title ??= 'Audio Note';

      // Create content with title and transcription as blockquote
      final contentJson = _createNoteContentWithTranscription(
        title,
        result.transcription,
      );

      final note = Note(
        title: title,
        content: contentJson,
        plainText: result.transcription ?? '',
      );

      // Add recording to note
      note.addRecording(
        NoteRecording(
          src: result.path,
          title: result.title ?? 'Audio Recording',
          length: result.length,
          transcript: result.transcription,
        ),
      );

      await note.save();

      if (mounted) {
        // Open the note in editor
        showPage(context, NoteEditor(note: note));
      }
    }
  }

  /// Create note content JSON with title and optional transcription blockquote
  String _createNoteContentWithTranscription(
    String title,
    String? transcription,
  ) {
    final List<Map<String, dynamic>> delta = [
      {'insert': title},
      {
        'insert': '\n',
        'attributes': {'header': 1},
      },
    ];

    if (transcription != null && transcription.isNotEmpty) {
      delta.add({'insert': transcription});
      delta.add({
        'insert': '\n',
        'attributes': {'blockquote': true},
      });
    }

    delta.add({'insert': '\n'});
    return json.encode(delta);
  }

  /// Create a new image note
  Future<void> _createImageNote() async {
    // On desktop, directly pick from gallery
    if (isDesktop) {
      await _pickImageAndCreateNote(ImageSource.gallery);
      return;
    }

    // On web, check if camera is available
    if (kIsWeb) {
      final hasCamera = await hasCameraAvailable();
      if (!hasCamera) {
        await _pickImageAndCreateNote(ImageSource.gallery);
        return;
      }
    }

    // Show bottom sheet with camera/gallery options (mobile or web with camera)
    _showImageSourceBottomSheet();
  }

  void _showImageSourceBottomSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Camera'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImageAndCreateNote(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.image),
                title: const Text('Gallery'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImageAndCreateNote(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const int _maxImageSize = 500 * 1024;

  Future<void> _pickImageAndCreateNote(ImageSource source) async {
    Uint8List? imageBytes;
    String ext = '.jpg';

    // On web with camera source, use the web camera capture
    if (kIsWeb && source == ImageSource.camera) {
      imageBytes = await captureImageFromWebCamera();
      if (imageBytes == null) return;
    } else {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: source);
      if (image == null) return;
      imageBytes = await image.readAsBytes();
      ext = path.extension(image.path);
      if (ext.isEmpty) ext = '.jpg';
    }

    // Show loading dialog
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const PopScope(
          canPop: false,
          child: Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Processing image...'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    try {
      final fs = await fileSystem();
      final documentDir = await fs.documentDir;
      final imagePath = path.join(documentDir, '${Uuid().v4()}$ext');

      // Compress the image
      Uint8List bytes = await _compressImageToTargetSize(imageBytes);

      await writeEncryptedBytes(imagePath, bytes);

      final decodedImage = await decodeImageFromList(bytes);
      final noteImage = NoteImage(
        src: imagePath,
        aspectRatio: "${decodedImage.width}:${decodedImage.height}",
        size: bytes.length,
        lastModified: DateTime.now().toIso8601String(),
        index: 0,
      );

      // Create note with image
      final note = Note(
        content: json.encode([
          {'insert': '\n'},
        ]),
        plainText: '',
      );
      note.addImage(noteImage);
      await note.save();

      // Dismiss loading dialog
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      // Open the note in editor
      if (mounted) {
        showPage(context, NoteEditor(note: note));
      }
    } catch (e) {
      // Dismiss loading dialog on error
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      snackbar('Failed to create image note', Colors.red);
    }
  }

  Future<Uint8List> _compressImageToTargetSize(Uint8List imageBytes) async {
    if (imageBytes.length <= _maxImageSize) {
      return await FlutterImageCompress.compressWithList(
        imageBytes,
        quality: 90,
      );
    }

    int quality = 85;
    int minWidth = 1920;
    int minHeight = 1920;
    Uint8List compressed = imageBytes;

    while (quality >= 50) {
      compressed = await FlutterImageCompress.compressWithList(
        imageBytes,
        quality: quality,
        minWidth: minWidth,
        minHeight: minHeight,
      );
      if (compressed.length <= _maxImageSize) return compressed;
      quality -= 10;
    }

    quality = 70;
    while (minWidth >= 800) {
      compressed = await FlutterImageCompress.compressWithList(
        imageBytes,
        quality: quality,
        minWidth: minWidth,
        minHeight: minHeight,
      );
      if (compressed.length <= _maxImageSize) return compressed;
      minWidth = (minWidth * 0.75).toInt();
      minHeight = (minHeight * 0.75).toInt();
    }

    return await FlutterImageCompress.compressWithList(
      imageBytes,
      quality: 50,
      minWidth: 800,
      minHeight: 800,
    );
  }

  /// Create a new todo note with empty checkbox
  Future<void> _createTodoNote() async {
    // Create content with title and empty unchecked checkbox
    // Format: Title + header attribute, then newline with unchecked list attribute
    final contentJson = json.encode([
      {'insert': 'Tasks'},
      {
        'insert': '\n',
        'attributes': {'header': 1},
      },
      {
        'insert': '\n',
        'attributes': {'list': 'unchecked'},
      },
    ]);

    final note = Note(title: 'Tasks', content: contentJson, plainText: 'Tasks');

    await note.save();

    if (mounted) {
      showPage(
        context,
        NoteEditor(note: note, autoFocus: true, deleteIfUnchanged: true),
      );
    }
  }
}
