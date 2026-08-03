import 'package:audioplayers/audioplayers.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/pages/about_page.dart';
import 'package:better_keep/pages/help_page.dart';
import 'package:better_keep/pages/settings/nerd_stats_page.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/services/whisper/whisper.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/themes/theme_registry.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

class Settings extends StatefulWidget {
  const Settings({super.key});

  @override
  State<Settings> createState() => _SettingsState();
}

class _SettingsState extends State<Settings> {
  String _themeId = AppState.themeId;
  bool _followSystemTheme = AppState.followSystemTheme;
  bool _followSystemAnimations = AppState.followSystemAnimations;
  String _darkThemeId = AppState.darkThemeId;
  String _lightThemeId = AppState.lightThemeId;
  String _alarmSound = AppState.alarmSound;
  bool _showSyncProgress = AppState.showSyncProgress;
  TimeOfDay _morningTime = AppState.morningTime;
  TimeOfDay _afternoonTime = AppState.afternoonTime;
  TimeOfDay _eveningTime = AppState.eveningTime;
  Locale? _locale = AppState.locale;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final bool _alarmSupported =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  // Local data protection state
  bool _notesEncryptionEnabled = false;
  bool _filesEncryptionEnabled = false;
  bool _localEncryptionAvailable = false;
  bool _forgetLockedNotePassword = AppState.forgetLockedNotePassword;

  final List<String> _sounds = [
    'assets/sounds/1.mp3',
    'assets/sounds/2.mp3',
    'assets/sounds/3.mp3',
    'assets/sounds/4.mp3',
    'assets/sounds/5.mp3',
    'assets/sounds/6.mp3',
    'assets/sounds/7.mp3',
    'assets/sounds/8.mp3',
    'assets/sounds/9.mp3',
  ];

  @override
  void initState() {
    super.initState();
    _fetchLocalEncryptionState();
    AppState.subscribe("theme_id", _themeIdListener);
    AppState.subscribe("follow_system_theme", _followSystemThemeListener);
    AppState.subscribe(
      "follow_system_animations",
      _followSystemAnimationsListener,
    );
    AppState.subscribe("dark_theme_id", _darkThemeIdListener);
    AppState.subscribe("light_theme_id", _lightThemeIdListener);
    AppState.subscribe("alarm_sound", _alarmListener);
    AppState.subscribe("show_sync_progress", _showSyncProgressListener);
    AppState.subscribe("morning_time", _morningTimeListener);
    AppState.subscribe("afternoon_time", _afternoonTimeListener);
    AppState.subscribe("evening_time", _eveningTimeListener);
    AppState.subscribe(
      "forget_locked_note_password",
      _forgetLockedNotePasswordListener,
    );
    AppState.subscribe("locale", _localeListener);
  }

  @override
  void dispose() {
    AppState.unsubscribe("theme_id", _themeIdListener);
    AppState.unsubscribe("follow_system_theme", _followSystemThemeListener);
    AppState.unsubscribe(
      "follow_system_animations",
      _followSystemAnimationsListener,
    );
    AppState.unsubscribe("dark_theme_id", _darkThemeIdListener);
    AppState.unsubscribe("light_theme_id", _lightThemeIdListener);
    AppState.unsubscribe("alarm_sound", _alarmListener);
    AppState.unsubscribe("show_sync_progress", _showSyncProgressListener);
    AppState.unsubscribe("morning_time", _morningTimeListener);
    AppState.unsubscribe("afternoon_time", _afternoonTimeListener);
    AppState.unsubscribe("evening_time", _eveningTimeListener);
    AppState.unsubscribe(
      "forget_locked_note_password",
      _forgetLockedNotePasswordListener,
    );
    AppState.unsubscribe("locale", _localeListener);
    _audioPlayer.dispose();
    super.dispose();
  }

  void _themeIdListener(dynamic value) {
    setState(() {
      _themeId = value as String;
    });
  }

  void _followSystemThemeListener(dynamic value) {
    setState(() {
      _followSystemTheme = value as bool;
    });
  }

  void _followSystemAnimationsListener(dynamic value) {
    setState(() {
      _followSystemAnimations = value as bool;
    });
  }

  void _forgetLockedNotePasswordListener(dynamic value) {
    setState(() {
      _forgetLockedNotePassword = value as bool;
    });
  }

  void _darkThemeIdListener(dynamic value) {
    setState(() {
      _darkThemeId = value as String;
    });
  }

  void _lightThemeIdListener(dynamic value) {
    setState(() {
      _lightThemeId = value as String;
    });
  }

  void _alarmListener(dynamic value) {
    setState(() {
      _alarmSound = value as String;
    });
  }

  void _showSyncProgressListener(dynamic value) {
    setState(() {
      _showSyncProgress = value as bool;
    });
  }

  void _morningTimeListener(dynamic value) {
    setState(() {
      _morningTime = value as TimeOfDay;
    });
  }

  void _afternoonTimeListener(dynamic value) {
    setState(() {
      _afternoonTime = value as TimeOfDay;
    });
  }

  void _eveningTimeListener(dynamic value) {
    setState(() {
      _eveningTime = value as TimeOfDay;
    });
  }

  void _localeListener(dynamic value) {
    setState(() {
      _locale = value as Locale?;
    });
  }

  String _getLanguageName(Locale? locale) {
    if (locale == null) {
      final l10n = AppLocalizations.of(context);
      return l10n?.systemDefault ?? 'System default';
    }
    switch (locale.languageCode) {
      case 'en':
        return 'English';
      case 'ja':
        return '日本語 (Japanese)';
      case 'ko':
        return '한국어 (Korean)';
      case 'id':
        return 'Bahasa Indonesia';
      case 'pt':
        return 'Português (Brazil)';
      case 'zh':
        return '中文 (Chinese)';
      default:
        return locale.languageCode;
    }
  }

  void _showLanguagePicker() {
    final supportedLocales = [
      null, // System default
      const Locale('en'),
      const Locale('ja'),
      const Locale('ko'),
      const Locale('id'),
      const Locale('pt', 'BR'),
      const Locale('zh'),
    ];

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            children: supportedLocales.map((locale) {
              final isSelected = _locale?.languageCode == locale?.languageCode;
              return ListTile(
                leading: isSelected
                    ? const Icon(Icons.check)
                    : const SizedBox(width: 24),
                title: Text(_getLanguageName(locale)),
                onTap: () {
                  AppState.locale = locale;
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  String _formatTime(TimeOfDay time) {
    return time.format(context);
  }

  Future<void> _pickTime(
    String label,
    TimeOfDay currentTime,
    Function(TimeOfDay) onSet,
  ) async {
    final time = await showTimePicker(
      context: context,
      initialTime: currentTime,
      helpText: 'Select $label time',
    );
    if (time != null) {
      onSet(time);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = ThemeRegistry.isDarkTheme(_themeId);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.settings)),
      body: ListView(
        children: [
          // Theme Settings Section
          ListTile(
            title: Text(
              context.l10n.theme,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(context.l10n.customizeAppearance),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.brightness_auto),
            title: Text(context.l10n.followSystemTheme),
            subtitle: Text(context.l10n.autoSwitchLightDark),
            value: _followSystemTheme,
            onChanged: (value) {
              AppState.followSystemTheme = value;
            },
          ),
          // Dark mode toggle - disabled when following system theme
          SwitchListTile(
            secondary: Icon(isDarkMode ? Icons.dark_mode : Icons.light_mode),
            title: Text(context.l10n.darkMode),
            value: isDarkMode,
            onChanged: _followSystemTheme
                ? null
                : (value) {
                    if (value) {
                      AppState.themeId = _darkThemeId;
                    } else {
                      AppState.themeId = _lightThemeId;
                    }
                  },
          ),
          // Theme selector - disabled when following system theme
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(
              isDarkMode ? context.l10n.darkTheme : context.l10n.lightTheme,
            ),
            subtitle: Text(
              ThemeRegistry.getThemeName(
                isDarkMode ? _darkThemeId : _lightThemeId,
              ),
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: !_followSystemTheme,
            onTap: _followSystemTheme
                ? null
                : () => _showThemePicker(isDarkMode),
          ),
          SystemAnimationPreferenceTile(
            value: _followSystemAnimations,
            onChanged: (value) {
              AppState.followSystemAnimations = value;
            },
          ),
          const Divider(),

          // Language Settings Section
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(context.l10n.language),
            subtitle: Text(_getLanguageName(_locale)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showLanguagePicker,
          ),
          const Divider(),

          // General Settings
          SwitchListTile(
            secondary: const Icon(Icons.sync),
            title: Text(context.l10n.showSyncProgress),
            subtitle: Text(context.l10n.displaySyncStatus),
            value: _showSyncProgress,
            onChanged: (value) {
              AppState.showSyncProgress = value;
            },
          ),
          if (_alarmSupported) ...[
            ListTile(
              leading: const Icon(Icons.alarm),
              title: Text(context.l10n.alarmSound),
              subtitle: Text(path.basenameWithoutExtension(_alarmSound)),
              onTap: _showSoundPicker,
            ),
          ],
          const Divider(),

          // Time Settings Section
          ListTile(
            title: Text(
              context.l10n.reminderTimeSettings,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(context.l10n.setDefaultTimes),
          ),
          ListTile(
            leading: const Icon(Icons.wb_sunny_outlined),
            title: Text(context.l10n.morning),
            subtitle: Text(_formatTime(_morningTime)),
            onTap: () => _pickTime(context.l10n.morning, _morningTime, (time) {
              AppState.morningTime = time;
            }),
          ),
          ListTile(
            leading: const Icon(Icons.wb_sunny),
            title: Text(context.l10n.afternoon),
            subtitle: Text(_formatTime(_afternoonTime)),
            onTap: () =>
                _pickTime(context.l10n.afternoon, _afternoonTime, (time) {
                  AppState.afternoonTime = time;
                }),
          ),
          ListTile(
            leading: const Icon(Icons.nights_stay_outlined),
            title: Text(context.l10n.evening),
            subtitle: Text(_formatTime(_eveningTime)),
            onTap: () => _pickTime(context.l10n.evening, _eveningTime, (time) {
              AppState.eveningTime = time;
            }),
          ),
          const Divider(),

          // Local Data Protection Section
          if (_localEncryptionAvailable) ...[
            ListTile(
              title: Text(
                context.l10n.localDataProtection,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(context.l10n.encryptDataOnDevice),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.article_outlined),
              title: Text(context.l10n.encryptNoteContent),
              subtitle: Text(context.l10n.encryptNotesInDatabase),
              value: _notesEncryptionEnabled,
              onChanged: _toggleNotesEncryption,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.image_outlined),
              title: Text(context.l10n.encryptAttachments),
              subtitle: Text(context.l10n.encryptImagesSketchesFiles),
              value: _filesEncryptionEnabled,
              onChanged: _toggleFilesEncryption,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.l10n.localEncryptionInfo,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(),
          ],

          // Locked Notes Section
          ListTile(
            title: Text(
              context.l10n.lockedNotes,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(context.l10n.privacyLockedNotes),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.lock_clock),
            title: Text(context.l10n.forgetPasswordOnClose),
            subtitle: Text(context.l10n.requireReenterPin),
            value: _forgetLockedNotePassword,
            onChanged: (value) {
              AppState.forgetLockedNotePassword = value;
            },
          ),
          const Divider(),

          // About & Help Section
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: Text(context.l10n.help),
            subtitle: Text(context.l10n.faqAndSupport),
            onTap: () {
              showPage(context, const HelpPage());
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(context.l10n.about),
            subtitle: Text(context.l10n.appInfoCredits),
            onTap: () {
              showPage(context, const AboutPage());
            },
          ),
          const Divider(),

          // Advanced Settings Section
          ListTile(
            title: Text(
              context.l10n.advancedSettings,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(context.l10n.developer),
          ),
          // Speech Recognition Model
          if (!kIsWeb) ...[_WhisperModelTile()],
          ListTile(
            leading: const Icon(Icons.analytics),
            title: Text(context.l10n.nerdStats),
            subtitle: Text(context.l10n.viewDatabaseStats),
            onTap: () {
              showPage(context, const NerdStatsPage());
            },
          ),
          if (kDebugMode)
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Firebase environment'),
              subtitle: Text(
                FirebaseEmulatorConfig.isUsingEmulators
                    ? 'Emulator · '
                          '${FirebaseEmulatorConfig.endpoints.host} · '
                          '${FirebaseEmulatorConfig.googleAuthMode.name} Google'
                    : 'Live Firebase',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showFirebaseEnvironmentDialog,
            ),
        ],
      ),
    );
  }

  Future<void> _showFirebaseEnvironmentDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Firebase environment'),
        content: Text(
          FirebaseEmulatorConfig.isUsingEmulators
              ? 'This process is connected to the emulator at '
                    '${FirebaseEmulatorConfig.endpoints.host}.\n\n'
                    'Firebase routing cannot be changed safely after startup. '
                    'You will choose the environment again on the next debug '
                    'launch.'
              : 'This process is connected to live Firebase.\n\n'
                    'Firebase routing cannot be changed safely after startup. '
                    'You will choose the environment again on the next debug '
                    'launch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showSoundPicker() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            children: _sounds.map((sound) {
              final name = path.basenameWithoutExtension(sound);
              return ListTile(
                leading: _alarmSound == sound
                    ? const Icon(Icons.check)
                    : const Icon(Icons.music_note),
                title: Text(name),
                trailing: IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () async {
                    try {
                      await _audioPlayer.stop();
                      // audioplayers prefers using AssetSource directly over temp files
                      final assetPath = sound.startsWith('assets/')
                          ? sound.substring('assets/'.length)
                          : sound;
                      await _audioPlayer.play(AssetSource(assetPath));
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              context.l10n.errorPlayingSound(e.toString()),
                            ),
                          ),
                        );
                      }
                    }
                  },
                ),
                onTap: () {
                  AppState.alarmSound = sound;
                  Navigator.pop(context);
                },
              );
            }).toList(),
          ),
        );
      },
    ).whenComplete(() {
      _audioPlayer.stop();
    });
  }

  void _showThemePicker(bool isDark) {
    final themes = isDark
        ? ThemeRegistry.darkThemes
        : ThemeRegistry.lightThemes;
    final themeNames = isDark
        ? ThemeRegistry.darkThemeNames
        : ThemeRegistry.lightThemeNames;
    final currentThemeId = isDark ? _darkThemeId : _lightThemeId;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          expand: false,
          builder: (context, scrollController) {
            return SafeArea(
              top: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      isDark
                          ? context.l10n.selectDarkTheme
                          : context.l10n.selectLightTheme,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: themes.length,
                      itemBuilder: (context, index) {
                        final themeId = themes.keys.elementAt(index);
                        final themeName = themeNames[themeId] ?? themeId;
                        final themeData = themes[themeId]!;
                        final isSelected = currentThemeId == themeId;

                        return ListTile(
                          leading: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey.withValues(alpha: 0.3),
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(7),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Container(
                                      color: themeData.scaffoldBackgroundColor,
                                    ),
                                  ),
                                  Expanded(
                                    child: Container(
                                      color: themeData.colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          title: Text(themeName),
                          trailing: isSelected
                              ? Icon(
                                  Icons.check_circle,
                                  color: Theme.of(context).colorScheme.primary,
                                )
                              : null,
                          onTap: () {
                            if (isDark) {
                              AppState.darkThemeId = themeId;
                            } else {
                              AppState.lightThemeId = themeId;
                            }
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _fetchLocalEncryptionState() async {
    final available = LocalDataEncryption.isAvailable;
    if (!available) return;

    final notesEnabled = await LocalDataEncryption.instance.isNotesEnabled();
    final filesEnabled = await LocalDataEncryption.instance.isFilesEnabled();

    if (mounted) {
      setState(() {
        _localEncryptionAvailable = available;
        _notesEncryptionEnabled = notesEnabled;
        _filesEncryptionEnabled = filesEnabled;
      });
    }
  }

  Future<void> _toggleNotesEncryption(bool enabled) async {
    await LocalDataEncryption.instance.setNotesEnabled(enabled);
    if (mounted) {
      setState(() {
        _notesEncryptionEnabled = enabled;
      });

      if (enabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.encryptingNotes),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );

        try {
          final migratedCount = await LocalDataEncryption.instance
              .migrateExistingNotes();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  migratedCount > 0
                      ? context.l10n.noteEncryptionEnabled(migratedCount)
                      : context.l10n.noteEncryptionEnabledSimple,
                ),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(context.l10n.errorEncryptingNotes(e.toString())),
                behavior: SnackBarBehavior.floating,
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.noteEncryptionDisabled),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _toggleFilesEncryption(bool enabled) async {
    await LocalDataEncryption.instance.setFilesEnabled(enabled);
    if (mounted) {
      setState(() {
        _filesEncryptionEnabled = enabled;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enabled
                ? context.l10n.fileEncryptionEnabled
                : context.l10n.fileEncryptionDisabled,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

/// Reusable presentation for the opt-in system animation preference.
class SystemAnimationPreferenceTile extends StatelessWidget {
  const SystemAnimationPreferenceTile({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.animation),
      title: Text(context.l10n.followSystemAnimations),
      subtitle: Text(context.l10n.reduceAnimationsFromSystem),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Widget for managing Whisper model in settings
class _WhisperModelTile extends StatefulWidget {
  @override
  State<_WhisperModelTile> createState() => _WhisperModelTileState();
}

class _WhisperModelTileState extends State<_WhisperModelTile> {
  final WhisperModelService _modelService = WhisperModelService.instance;
  bool _isDownloaded = false;
  bool _isDownloading = false;
  double _downloadProgress = 0;
  int _modelSize = 0;

  @override
  void initState() {
    super.initState();
    _checkModelStatus();
  }

  Future<void> _checkModelStatus() async {
    final downloaded = await _modelService.isModelDownloaded();
    final size = await _modelService.getDownloadedModelSize();
    if (mounted) {
      setState(() {
        _isDownloaded = downloaded;
        _modelSize = size;
      });
    }
  }

  Future<void> _downloadModel() async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
    });

    final path = await _modelService.downloadModel(
      onProgress: (received, total) {
        if (mounted) {
          setState(() {
            _downloadProgress = total > 0 ? received / total : 0;
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _isDownloading = false;
        _isDownloaded = path != null;
      });

      await _checkModelStatus();

      if (mounted) {
        final colorScheme = Theme.of(context).colorScheme;
        final l10n = context.l10n;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              path != null
                  ? l10n.modelDownloadComplete
                  : l10n.modelDownloadFailed,
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: path != null ? null : colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _deleteModel() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteQuestion),
        content: Text(context.l10n.deleteWhisperModelConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _modelService.deleteModel();
      await _checkModelStatus();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.whisperModelDeleted),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return ListTile(
      leading: const Icon(Icons.record_voice_over),
      title: Text(l10n.speechRecognitionModel),
      subtitle: _isDownloading
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(value: _downloadProgress),
                const SizedBox(height: 4),
                Text('${(_downloadProgress * 100).toInt()}%'),
              ],
            )
          : Text(
              _isDownloaded
                  ? l10n.whisperModelDownloaded(_formatBytes(_modelSize))
                  : l10n.whisperModelNotDownloaded(
                      _formatBytes(
                        WhisperModelService
                            .defaultModelSize
                            .approximateSizeBytes,
                      ),
                    ),
            ),
      trailing: _isDownloading
          ? null
          : _isDownloaded
          ? IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteModel,
              tooltip: l10n.deleteModel,
            )
          : FilledButton.tonal(
              onPressed: _downloadModel,
              child: Text(l10n.download),
            ),
    );
  }
}
