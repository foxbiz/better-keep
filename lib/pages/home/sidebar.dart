import 'dart:async';
import 'dart:io' show Platform;

import 'package:better_keep/components/logo.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/dialogs/labels.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/settings.dart';
import 'package:better_keep/services/app_install_service.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/paywall/paywall.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

class Sidebar extends StatefulWidget {
  final bool shrink;
  const Sidebar({super.key, this.shrink = false});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  bool _isBigScreen = false;
  AppInstallInfo? _installInfo;
  StreamSubscription<void>? _installableSubscription;

  @override
  void initState() {
    super.initState();
    _loadInstallInfo();

    if (kIsWeb) {
      _installableSubscription = AppInstallService.instance.onInstallable
          .listen((_) {
            _loadInstallInfo();
          });
    }
  }

  @override
  void dispose() {
    _installableSubscription?.cancel();
    super.dispose();
  }

  void _loadInstallInfo() {
    if (kIsWeb) {
      setState(() {
        _installInfo = AppInstallService.instance.getInstallInfo();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isBigScreen = MediaQuery.of(context).size.width >= bigScreenWidthThreshold;
  }

  void _handleInstallTap() {
    final info = _installInfo;
    if (info == null) return;

    if (info.isIOS) {
      _showIOSInstallDialog();
    } else {
      AppInstallService.instance.handleInstallAction();
    }
  }

  void _showIOSInstallDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.apple, size: 28),
            SizedBox(width: 12),
            Text('Install Better Keep'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '📱 iOS App Coming Soon!',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            SizedBox(height: 12),
            Text(
              'Our iOS app is being reviewed. In the meantime, you can install the web app:',
            ),
            SizedBox(height: 16),
            Text('1. Tap the Share button in Safari'),
            SizedBox(height: 8),
            Text('2. Scroll down and tap "Add to Home Screen"'),
            SizedBox(height: 8),
            Text('3. Tap "Add" to install'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showInstallButton =
        kIsWeb && (_installInfo?.shouldShowInstallButton ?? false);

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: <Widget>[
                if (!_isBigScreen) Logo(),
                _buildTile(Icons.note, 'Notes', () {
                  if (!_isBigScreen) Navigator.pop(context);
                  AppState.showNotes = NoteType.all;
                }, AppState.showNotes == NoteType.all),
                _buildTile(Icons.label, 'Labels', () {
                  labels(context);
                }),
                _buildTile(Icons.archive, 'Archive', () {
                  if (!_isBigScreen) Navigator.pop(context);
                  AppState.showNotes = NoteType.archived;
                }, AppState.showNotes == NoteType.archived),
                _buildTile(Icons.alarm, 'Reminders', () {
                  if (!_isBigScreen) Navigator.pop(context);
                  AppState.showNotes = NoteType.reminder;
                }, AppState.showNotes == NoteType.reminder),
                _buildTile(Icons.delete, 'Trash', () {
                  if (!_isBigScreen) Navigator.pop(context);
                  AppState.showNotes = NoteType.trashed;
                }, AppState.showNotes == NoteType.trashed),
                _buildTile(Icons.settings, 'Settings', () {
                  if (!_isBigScreen) Navigator.pop(context);
                  showPage(context, const Settings());
                }),
                if (!kIsWeb && Platform.isAndroid)
                  _buildTile(Icons.share, 'Share App', () {
                    SharePlus.instance.share(
                      ShareParams(
                        text:
                            'Check out Better Keep Notes - a secure note-taking app!\nhttps://play.google.com/store/apps/details?id=io.foxbiz.better_keep',
                      ),
                    );
                  }),
              ],
            ),
          ),
          if (showInstallButton) _buildInstallButton(),
          ValueListenableBuilder<SubscriptionStatus>(
            valueListenable: PlanService.instance.statusNotifier,
            builder: (context, status, _) {
              if (status.effectivePlan != UserPlan.free) {
                return const SizedBox.shrink();
              }
              return _buildTile(Icons.workspace_premium, 'Upgrade to Pro', () {
                if (!_isBigScreen) Navigator.pop(context);
                showPaywall(context);
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInstallButton() {
    final info = _installInfo;
    if (info == null) return const SizedBox.shrink();

    IconData icon;
    String label;

    if (info.isIOS) {
      icon = Icons.install_mobile;
      label = 'Install App';
    } else if (info.isAndroid) {
      icon = Icons.android;
      label = 'Get Android App';
    } else if (info.isWindows) {
      icon = Icons.desktop_windows;
      label = 'Get Windows App';
    } else if (info.isMacOS) {
      icon = Icons.laptop_mac;
      label = 'Install App';
    } else if (info.canInstallPWA) {
      icon = Icons.install_desktop;
      label = 'Install App';
    } else {
      icon = Icons.download;
      label = 'Install App';
    }

    return _buildTile(icon, label, _handleInstallTap);
  }

  Widget _buildTile(
    IconData icon,
    String title,
    VoidCallback onTap, [
    bool selected = false,
  ]) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final listTileTheme = theme.listTileTheme;

    final selectedTileColor =
        listTileTheme.selectedTileColor ?? colorScheme.secondaryContainer;
    final selectedColor =
        listTileTheme.selectedColor ?? colorScheme.onSecondaryContainer;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: widget.shrink
          ? const EdgeInsets.only(right: 24.0)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: selected ? selectedTileColor : Colors.transparent,
        borderRadius: BorderRadius.circular(widget.shrink ? 16.0 : 0.0),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(widget.shrink ? 16.0 : 0.0),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 56.0,
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Icon(icon, color: selected ? selectedColor : null),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: widget.shrink ? 0 : 32.0,
                ),
                Expanded(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: widget.shrink ? 0.0 : 1.0,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected ? selectedColor : null,
                        fontWeight: FontWeight.w500,
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
  }
}
