import 'package:audioplayers/audioplayers.dart';
import 'package:better_keep/pages/about_page.dart';
import 'package:better_keep/pages/help_page.dart';
import 'package:better_keep/pages/nerd_stats_page.dart';
import 'package:better_keep/services/local_data_encryption.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/themes/theme_registry.dart';
import 'package:better_keep/ui/show_page.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
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
  String _darkThemeId = AppState.darkThemeId;
  String _lightThemeId = AppState.lightThemeId;
  String _alarmSound = AppState.alarmSound;
  bool _showSyncProgress = AppState.showSyncProgress;
  TimeOfDay _morningTime = AppState.morningTime;
  TimeOfDay _afternoonTime = AppState.afternoonTime;
  TimeOfDay _eveningTime = AppState.eveningTime;
  final AudioPlayer _audioPlayer = AudioPlayer();
  final bool _alarmSupported =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  // Local data protection state
  bool _notesEncryptionEnabled = false;
  bool _filesEncryptionEnabled = false;
  bool _localEncryptionAvailable = false;

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
    AppState.subscribe("dark_theme_id", _darkThemeIdListener);
    AppState.subscribe("light_theme_id", _lightThemeIdListener);
    AppState.subscribe("alarm_sound", _alarmListener);
    AppState.subscribe("show_sync_progress", _showSyncProgressListener);
    AppState.subscribe("morning_time", _morningTimeListener);
    AppState.subscribe("afternoon_time", _afternoonTimeListener);
    AppState.subscribe("evening_time", _eveningTimeListener);
  }

  @override
  void dispose() {
    AppState.unsubscribe("theme_id", _themeIdListener);
    AppState.unsubscribe("follow_system_theme", _followSystemThemeListener);
    AppState.unsubscribe("dark_theme_id", _darkThemeIdListener);
    AppState.unsubscribe("light_theme_id", _lightThemeIdListener);
    AppState.unsubscribe("alarm_sound", _alarmListener);
    AppState.unsubscribe("show_sync_progress", _showSyncProgressListener);
    AppState.unsubscribe("morning_time", _morningTimeListener);
    AppState.unsubscribe("afternoon_time", _afternoonTimeListener);
    AppState.unsubscribe("evening_time", _eveningTimeListener);
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

  String _formatTime(TimeOfDay time) {
    final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
    final minute = time.minute.toString().padLeft(2, '0');
    final period = time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour:$minute $period';
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
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // Theme Settings Section
          const ListTile(
            title: Text('Theme', style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('Customize app appearance'),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.brightness_auto),
            title: const Text('Follow System Theme'),
            subtitle: const Text('Automatically switch between light and dark'),
            value: _followSystemTheme,
            onChanged: (value) {
              AppState.followSystemTheme = value;
            },
          ),
          // Dark mode toggle - disabled when following system theme
          SwitchListTile(
            secondary: Icon(isDarkMode ? Icons.dark_mode : Icons.light_mode),
            title: const Text('Dark Mode'),
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
            title: Text(isDarkMode ? 'Dark Theme' : 'Light Theme'),
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
          const Divider(),

          // General Settings
          SwitchListTile(
            secondary: const Icon(Icons.sync),
            title: const Text('Show Sync Progress'),
            subtitle: const Text('Display sync status indicator'),
            value: _showSyncProgress,
            onChanged: (value) {
              AppState.showSyncProgress = value;
            },
          ),
          if (_alarmSupported) ...[
            ListTile(
              leading: const Icon(Icons.alarm),
              title: const Text('Alarm Sound'),
              subtitle: Text(path.basenameWithoutExtension(_alarmSound)),
              onTap: _showSoundPicker,
            ),
          ],
          const Divider(),

          // Time Settings Section
          const ListTile(
            title: Text(
              'Reminder Time Settings',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('Set default times for reminders'),
          ),
          ListTile(
            leading: const Icon(Icons.wb_sunny_outlined),
            title: const Text('Morning'),
            subtitle: Text(_formatTime(_morningTime)),
            onTap: () => _pickTime('Morning', _morningTime, (time) {
              AppState.morningTime = time;
            }),
          ),
          ListTile(
            leading: const Icon(Icons.wb_sunny),
            title: const Text('Afternoon'),
            subtitle: Text(_formatTime(_afternoonTime)),
            onTap: () => _pickTime('Afternoon', _afternoonTime, (time) {
              AppState.afternoonTime = time;
            }),
          ),
          ListTile(
            leading: const Icon(Icons.nights_stay_outlined),
            title: const Text('Evening'),
            subtitle: Text(_formatTime(_eveningTime)),
            onTap: () => _pickTime('Evening', _eveningTime, (time) {
              AppState.eveningTime = time;
            }),
          ),
          const Divider(),

          // Local Data Protection Section
          if (_localEncryptionAvailable) ...[
            const ListTile(
              title: Text(
                'Local Data Protection',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text('Encrypt data stored on this device'),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.article_outlined),
              title: const Text('Encrypt Note Content'),
              subtitle: const Text('Encrypt notes in local database'),
              value: _notesEncryptionEnabled,
              onChanged: _toggleNotesEncryption,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.image_outlined),
              title: const Text('Encrypt Attachments'),
              subtitle: const Text('Encrypt images, sketches, and files'),
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
                        'Local encryption protects your data if your device is compromised. '
                        'Uses AES-256-GCM encryption.',
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

          // About & Help Section
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Help'),
            subtitle: const Text('FAQ and contact support'),
            onTap: () {
              showPage(context, const HelpPage());
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            subtitle: const Text('App info and credits'),
            onTap: () {
              showPage(context, const AboutPage());
            },
          ),
          const Divider(),

          // Advanced Settings Section
          const ListTile(
            title: Text(
              'Advanced Settings',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('Developer and recovery options'),
          ),
          ListTile(
            leading: const Icon(Icons.analytics),
            title: const Text('Nerd Stats'),
            subtitle: const Text('View database and sync statistics'),
            onTap: () {
              showPage(context, const NerdStatsPage());
            },
          ),
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Recover Old Notes'),
            subtitle: const Text('Restore notes from a previous account'),
            onTap: () {
              _showRecoverOldNotesDialog();
            },
          ),
        ],
      ),
    );
  }

  void _showSoundPicker() {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        return ListView(
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
                        SnackBar(content: Text('Error playing sound: $e')),
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
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    isDark ? 'Select Dark Theme' : 'Select Light Theme',
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
            );
          },
        );
      },
    );
  }

  void _showRecoverOldNotesDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Recover Old Notes'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'If you previously started fresh without a recovery key, '
                'your old notes may still be recoverable if you remember your recovery passphrase.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Text(
                'This feature is coming soon.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
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
          const SnackBar(
            content: Text('Encrypting existing notes...'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
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
                      ? 'Note encryption enabled. $migratedCount notes encrypted.'
                      : 'Note encryption enabled.',
                ),
                behavior: SnackBarBehavior.floating,
                backgroundColor: Colors.green,
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error encrypting notes: $e'),
                behavior: SnackBarBehavior.floating,
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Note encryption disabled.'),
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
                ? 'File encryption enabled. New attachments will be encrypted.'
                : 'File encryption disabled.',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: enabled ? Colors.green : null,
        ),
      );
    }
  }
}
