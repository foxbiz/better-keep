import 'package:better_keep/models/note.dart';
import 'package:flutter/material.dart';

/// Result of grouping notes into folders
class NoteGroups {
  /// Pinned notes (shown as "Pinned" folder first)
  final List<Note> pinnedNotes;

  /// Notes grouped by label (note can appear in multiple groups)
  final Map<String, List<Note>> byLabel;

  /// Notes grouped by color
  final Map<Color, List<Note>> byColor;

  const NoteGroups({
    required this.pinnedNotes,
    required this.byLabel,
    required this.byColor,
  });
}

/// Groups notes by their labels.
/// Notes with multiple labels appear in each label's folder.
/// Notes without labels go into "Unlabeled" folder.
Map<String, List<Note>> groupNotesByLabel(List<Note> notes) {
  final Map<String, List<Note>> groups = {};

  for (final note in notes) {
    if (note.pinned) continue; // Pinned notes are handled separately

    final labelString = note.labels?.trim();
    if (labelString == null || labelString.isEmpty) {
      groups.putIfAbsent('Unlabeled', () => []).add(note);
    } else {
      final labels = labelString
          .split(',')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty);
      for (final label in labels) {
        groups.putIfAbsent(label, () => []).add(note);
      }
    }
  }

  return groups;
}

/// Groups notes by their color.
/// Notes with transparent/no color go into a "No Color" group (represented by Colors.transparent).
Map<Color, List<Note>> groupNotesByColor(List<Note> notes) {
  final Map<Color, List<Note>> groups = {};

  for (final note in notes) {
    if (note.pinned) continue; // Pinned notes are handled separately

    final color = note.color == Colors.transparent
        ? Colors.transparent
        : note.color;
    groups.putIfAbsent(color, () => []).add(note);
  }

  return groups;
}

/// Extracts pinned notes from a list of notes.
List<Note> extractPinnedNotes(List<Note> notes) {
  return notes.where((note) => note.pinned).toList();
}

/// Creates complete note groupings with pinned notes separated.
NoteGroups createNoteGroups(List<Note> notes) {
  final pinnedNotes = extractPinnedNotes(notes);
  final byLabel = groupNotesByLabel(notes);
  final byColor = groupNotesByColor(notes);

  return NoteGroups(
    pinnedNotes: pinnedNotes,
    byLabel: byLabel,
    byColor: byColor,
  );
}
