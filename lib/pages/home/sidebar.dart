import 'dart:io' show Platform;

import 'package:better_keep/components/logo.dart';
import 'package:better_keep/config.dart';
import 'package:better_keep/dialogs/labels.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/settings.dart';
import 'package:better_keep/state.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _isBigScreen = MediaQuery.of(context).size.width >= bigScreenWidthThreshold;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
    );
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
