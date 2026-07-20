import 'dart:async';
import 'dart:io' show Platform;

import 'package:better_keep/components/logo.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/dialogs/labels.dart';
import 'package:better_keep/dialogs/snackbar.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/reminder.dart';
import 'package:better_keep/pages/settings/settings.dart';
import 'package:better_keep/services/app_install_service.dart';
import 'package:better_keep/services/monetization/monetization.dart';
import 'package:better_keep/services/reminder_permission_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/ui/paywall/paywall.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

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

  Future<void> _handleEnableNotifications() async {
    final service = ReminderPermissionService();
    final granted = await service.ensurePermissions(ReminderType.alarm);
    await service.checkAndNotify();
    if (granted) {
      await service.rescheduleAllAlarms();
      if (mounted) {
        snackbar(context.l10n.notificationsEnabled, Colors.green[400]);
      }
    }
  }

  void _handleInstallTap() {
    final info = _installInfo;
    if (info == null) return;

    AppInstallService.instance.handleInstallAction();
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
                _buildTile(
                  Icons.note,
                  context.l10n.notes,
                  () {
                    if (!_isBigScreen) Navigator.pop(context);
                    AppState.showNotes = NoteType.all;
                  },
                  selected: AppState.showNotes == NoteType.all,
                ),
                _buildTile(Icons.label, context.l10n.labels, () {
                  labels(context);
                }),
                _buildTile(
                  Icons.archive,
                  context.l10n.archive,
                  () {
                    if (!_isBigScreen) Navigator.pop(context);
                    AppState.showNotes = NoteType.archived;
                  },
                  selected: AppState.showNotes == NoteType.archived,
                ),
                _buildTile(
                  Icons.alarm,
                  context.l10n.reminders,
                  () {
                    if (!_isBigScreen) Navigator.pop(context);
                    AppState.showNotes = NoteType.reminder;
                  },
                  selected: AppState.showNotes == NoteType.reminder,
                ),
                _buildTile(
                  Icons.delete,
                  context.l10n.trash,
                  () {
                    if (!_isBigScreen) Navigator.pop(context);
                    AppState.showNotes = NoteType.trashed;
                  },
                  selected: AppState.showNotes == NoteType.trashed,
                ),
                _buildTile(Icons.settings, context.l10n.settings, () {
                  if (!_isBigScreen) Navigator.pop(context);
                  showPage(context, const Settings());
                }),
                if (!kIsWeb && Platform.isAndroid)
                  _buildTile(Icons.share, context.l10n.shareApp, () {
                    SharePlus.instance.share(
                      ShareParams(text: context.l10n.shareAppMessage),
                    );
                  }),
              ],
            ),
          ),
          if (isAlarmSupported)
            ValueListenableBuilder<bool>(
              valueListenable: ReminderPermissionService().permissionGranted,
              builder: (context, granted, _) {
                if (granted) return const SizedBox.shrink();
                return _buildTile(
                  Icons.notifications_off,
                  context.l10n.enableNotificationsTitle,
                  _handleEnableNotifications,
                  showBadge: true,
                );
              },
            ),
          if (showInstallButton) _buildInstallButton(),
          if (!kIsWeb && (!AppState.rateAppDismissed || kDebugMode))
            _buildRateAppTile(),
          ValueListenableBuilder<SubscriptionStatus>(
            valueListenable: PlanService.instance.statusNotifier,
            builder: (context, status, _) {
              if (status.effectivePlan != UserPlan.free) {
                return const SizedBox.shrink();
              }
              return _buildTile(
                Icons.workspace_premium,
                context.l10n.upgradeToPro,
                () {
                  if (!_isBigScreen) Navigator.pop(context);
                  showPaywall(context);
                },
              );
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
      label = context.l10n.installApp;
    } else if (info.isAndroid) {
      icon = Icons.android;
      label = context.l10n.getAndroidApp;
    } else if (info.isWindows) {
      icon = Icons.desktop_windows;
      label = context.l10n.getWindowsApp;
    } else if (info.isMacOS) {
      icon = Icons.laptop_mac;
      label = context.l10n.installApp;
    } else if (info.canInstallPWA) {
      icon = Icons.install_desktop;
      label = context.l10n.installApp;
    } else {
      icon = Icons.download;
      label = context.l10n.installApp;
    }

    return _buildTile(icon, label, _handleInstallTap);
  }

  Widget _buildRateAppTile() {
    final String url;
    final String label;

    if (Platform.isIOS || Platform.isMacOS) {
      url = appStoreUrl;
      label = context.l10n.rateOnAppStore;
    } else if (Platform.isWindows) {
      url = microsoftStoreUrl;
      label = context.l10n.rateOnMicrosoftStore;
    } else if (Platform.isAndroid) {
      url = playStoreUrl;
      label = context.l10n.rateOnPlayStore;
    } else {
      return const SizedBox.shrink();
    }

    return _buildTile(Icons.star_outline, label, () {
      AppState.rateAppDismissed = true;
      setState(() {});
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    });
  }

  Widget _buildTile(
    IconData icon,
    String title,
    VoidCallback onTap, {
    bool selected = false,
    bool showBadge = false,
  }) {
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
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(icon, color: selected ? selectedColor : null),
                    if (showBadge)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Colors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
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
