import 'dart:async';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WidgetService {
  static final WidgetService instance = WidgetService._();
  WidgetService._();

  static const _appGroupId = 'group.io.foxbiz.better-keep';
  static const _noteWidgetKeyPrefix = 'note_widget_id';
  static const _noteWidgetDataKeyPrefix = 'note_widget_data';
  static const _noteWidgetOptionsDataKey = 'note_widget_options_data';
  static const _noteListWidgetDataKey = 'note_list_widget_data';
  static const _noteWidgetProviderName = 'NoteWidget';
  static const _configuredNoteWidgetProviderName = 'ConfiguredNoteWidget';
  static const _noteListWidgetProviderName = 'NoteListWidget';
  static const _iosNoteWidgetSlotCount = 4;

  bool _initialized = false;
  Timer? _debounceTimer;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await HomeWidget.setAppGroupId(_appGroupId);

    Note.on('changed', (_) => _onNoteChanged());

    await _refreshNoteWidgets();
    await _refreshNoteListWidget();
  }

  void _onNoteChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      await Future.wait([_refreshNoteWidgets(), _refreshNoteListWidget()]);
    });
  }

  Future<void> setNoteWidget(int noteId, {int? widgetId, int? iosSlot}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _noteWidgetKey(widgetId: widgetId, iosSlot: iosSlot),
      noteId,
    );
    await _refreshNoteWidget(widgetId: widgetId, iosSlot: iosSlot);
  }

  Future<int?> getNoteWidgetNoteId({int? widgetId, int? iosSlot}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_noteWidgetKey(widgetId: widgetId, iosSlot: iosSlot));
  }

  Future<void> removeNoteWidget({int? widgetId, int? iosSlot}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_noteWidgetKey(widgetId: widgetId, iosSlot: iosSlot));
    await HomeWidget.saveWidgetData<String>(
      _noteWidgetDataKey(widgetId: widgetId, iosSlot: iosSlot),
      '',
    );
    await _updateNoteWidget(iosSlot: iosSlot);
  }

  Future<void> _refreshNoteWidgets() async {
    final prefs = await SharedPreferences.getInstance();
    final widgetIds = _selectedAndroidWidgetIds(prefs);
    final iosSlots = _selectedIosWidgetSlots(prefs);

    await Future.wait([
      ...widgetIds.map((widgetId) => _refreshNoteWidget(widgetId: widgetId)),
      ...iosSlots.map((iosSlot) => _refreshNoteWidget(iosSlot: iosSlot)),
    ]);
  }

  Future<void> _refreshNoteWidget({int? widgetId, int? iosSlot}) async {
    final noteId = await getNoteWidgetNoteId(
      widgetId: widgetId,
      iosSlot: iosSlot,
    );
    if (noteId == null) return;

    final note = await Note.findById(noteId);
    if (note == null || note.trashed) {
      await HomeWidget.saveWidgetData<String>(
        _noteWidgetDataKey(widgetId: widgetId, iosSlot: iosSlot),
        '',
      );
      await _updateNoteWidget(iosSlot: iosSlot);
      return;
    }

    final data = _serializeNote(note);
    await HomeWidget.saveWidgetData<String>(
      _noteWidgetDataKey(widgetId: widgetId, iosSlot: iosSlot),
      data,
    );
    await _updateNoteWidget(iosSlot: iosSlot);
  }

  List<int> _selectedAndroidWidgetIds(SharedPreferences prefs) {
    const prefix = '${_noteWidgetKeyPrefix}_';
    return prefs
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .map((key) => int.tryParse(key.substring(prefix.length)))
        .whereType<int>()
        .toList();
  }

  List<int> _selectedIosWidgetSlots(SharedPreferences prefs) {
    const prefix = '${_noteWidgetKeyPrefix}_ios_';
    return prefs
        .getKeys()
        .where((key) => key.startsWith(prefix))
        .map((key) => int.tryParse(key.substring(prefix.length)))
        .whereType<int>()
        .where((slot) => slot >= 1 && slot <= _iosNoteWidgetSlotCount)
        .toList();
  }

  String _noteWidgetKey({int? widgetId, int? iosSlot}) {
    if (widgetId != null) return '${_noteWidgetKeyPrefix}_$widgetId';
    if (iosSlot != null) return '${_noteWidgetKeyPrefix}_ios_$iosSlot';
    return _noteWidgetKeyPrefix;
  }

  String _noteWidgetDataKey({int? widgetId, int? iosSlot}) {
    if (widgetId != null) return '${_noteWidgetDataKeyPrefix}_$widgetId';
    if (iosSlot != null) return '${_noteWidgetDataKeyPrefix}_ios_$iosSlot';
    return _noteWidgetDataKeyPrefix;
  }

  Future<void> _updateNoteWidget({int? iosSlot}) {
    return HomeWidget.updateWidget(
      name: _noteWidgetProviderName,
      iOSName: _iosNoteWidgetKind(iosSlot ?? 1),
    );
  }

  String _iosNoteWidgetKind(int slot) {
    if (slot <= 1) return _noteWidgetProviderName;
    return '${_noteWidgetProviderName}_$slot';
  }

  Future<void> _refreshNoteListWidget() async {
    final notes = await Note.get(NoteType.all);
    final displayNotes = notes.where((n) => !n.trashed && !n.archived).toList()
      ..sort((a, b) {
        if (a.pinned && !b.pinned) return -1;
        if (!a.pinned && b.pinned) return 1;
        return (b.updatedAt ?? DateTime(0)).compareTo(
          a.updatedAt ?? DateTime(0),
        );
      });

    final limited = displayNotes.take(4).toList();
    final dataList = limited.map(_serializeNote).toList();
    final jsonStr = '[${dataList.join(',')}]';

    await HomeWidget.saveWidgetData<String>(_noteListWidgetDataKey, jsonStr);
    await HomeWidget.updateWidget(name: _noteListWidgetProviderName);

    final optionsJsonStr = '[${displayNotes.map(_serializeNote).join(',')}]';
    await HomeWidget.saveWidgetData<String>(
      _noteWidgetOptionsDataKey,
      optionsJsonStr,
    );
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await HomeWidget.updateWidget(iOSName: _configuredNoteWidgetProviderName);
    }
  }

  String _serializeNote(Note note) {
    final colorValue = note.color.toARGB32().toRadixString(16).padLeft(8, '0');
    final foregroundDark = isDark(note.color) ? 'true' : 'false';

    final labels = note.labels != null && note.labels!.isNotEmpty
        ? note.labels!
        : '';
    final labelList = labels
        .split(',')
        .where((l) => l.trim().isNotEmpty)
        .toList();

    final updatedAt = note.updatedAt ?? DateTime.now();
    final dateStr = '${updatedAt.day}/${updatedAt.month}/${updatedAt.year}';

    final checkbox = note.checkboxCount;
    final hasAttachments =
        note.images.isNotEmpty ||
        note.sketches.isNotEmpty ||
        note.recordings.isNotEmpty;

    return '''
{
  "noteId": ${note.id ?? 0},
  "title": ${_escapeJson(note.title ?? '')},
  "text": ${_escapeJson(note.plainText ?? '')},
  "colorHex": "$colorValue",
  "foregroundDark": $foregroundDark,
  "labels": ${_escapeJson(labelList.join(', '))},
  "pinned": ${note.pinned},
  "hasReminder": ${note.reminder != null},
  "checkboxChecked": ${checkbox.checked},
  "checkboxTotal": ${checkbox.total},
  "hasCheckboxes": ${note.hasCheckboxes},
  "updatedAt": "$dateStr",
  "locked": ${note.locked},
  "hasAttachments": $hasAttachments
}''';
  }

  String _escapeJson(String value) {
    return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r').replaceAll('\t', '\\t')}"';
  }
}
