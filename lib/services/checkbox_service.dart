import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

/// Represents a checkbox node in the document tree
class CheckboxNode {
  /// The offset of the newline character where this checkbox's attributes are stored
  final int offset;

  /// The indent level (0 = no indent, 1 = first level indent, etc.)
  final int indentLevel;

  /// Whether the checkbox is checked
  final bool isChecked;

  /// Index in the list of all checkbox nodes
  final int index;

  /// Whether there's a hierarchy-breaking gap before this node
  /// (e.g., plain text, empty line, or non-checkbox list item)
  final bool hasGapBefore;

  const CheckboxNode({
    required this.offset,
    required this.indentLevel,
    required this.isChecked,
    required this.index,
    this.hasGapBefore = false,
  });

  @override
  String toString() =>
      'CheckboxNode(offset: $offset, indent: $indentLevel, checked: $isChecked, index: $index, gap: $hasGapBefore)';
}

/// Result of detecting a checkbox change
class CheckboxChangeResult {
  /// The offset where the change occurred
  final int offset;

  /// The new checked state (true = checked, false = unchecked)
  final bool isChecked;

  /// The previous checked state
  final bool wasChecked;

  const CheckboxChangeResult({
    required this.offset,
    required this.isChecked,
    required this.wasChecked,
  });
}

/// Service to handle nested checkbox cascade and bubble logic
class CheckboxService {
  /// Cached list of checkbox nodes
  List<CheckboxNode>? _cachedNodes;

  /// Cached content for invalidation (direct comparison avoids hash collisions)
  String? _cachedContent;

  /// Map of offset to node index for O(1) lookup
  Map<int, int>? _offsetToIndexMap;

  /// Parse the document and return a list of checkbox nodes
  /// Uses caching for performance
  List<CheckboxNode> parseCheckboxTree(Document document) {
    final content = jsonEncode(document.toDelta().toJson());

    // Return cached result if content hasn't changed
    if (_cachedNodes != null && _cachedContent == content) {
      return _cachedNodes!;
    }

    final nodes = <CheckboxNode>[];
    final delta = document.toDelta();
    final ops = delta.toList();

    int currentOffset = 0;
    int nodeIndex = 0;
    bool hasGapSinceLastCheckbox =
        true; // First checkbox always has a "gap" (start of document)

    for (final op in ops) {
      if (!op.isInsert) continue;

      final data = op.data;
      final attrs = op.attributes;
      final length = data is String ? data.length : 1;

      // Check if this is a newline
      if (data == '\n') {
        final listAttr = attrs?['list'];

        // Only process checked/unchecked (not bullet/ordered)
        if (listAttr == 'checked' || listAttr == 'unchecked') {
          final indentAttr = attrs?['indent'];
          final indentLevel = indentAttr is int ? indentAttr : 0;

          nodes.add(
            CheckboxNode(
              offset: currentOffset,
              indentLevel: indentLevel,
              isChecked: listAttr == 'checked',
              index: nodeIndex,
              hasGapBefore: hasGapSinceLastCheckbox,
            ),
          );
          nodeIndex++;
          hasGapSinceLastCheckbox = false; // Reset gap flag
        } else {
          // This is a non-checkbox line (plain text, bullet, ordered, etc.)
          // Mark that there's a gap before the next checkbox
          hasGapSinceLastCheckbox = true;
        }
      }

      currentOffset += length;
    }

    // Update cache
    _cachedNodes = nodes;
    _cachedContent = content;
    _offsetToIndexMap = {for (final node in nodes) node.offset: node.index};

    return nodes;
  }

  /// Invalidate the cache (call when document structure changes)
  void invalidateCache() {
    _cachedNodes = null;
    _cachedContent = null;
    _offsetToIndexMap = null;
  }

  /// Detect if a checkbox state was changed from a DocChange event
  /// Returns the change details or null if no checkbox was toggled
  CheckboxChangeResult? detectChange(Delta before, Delta change) {
    // Look for retain operations with list attribute changes
    int offset = 0;

    for (final op in change.toList()) {
      if (op.isRetain) {
        final attrs = op.attributes;
        if (attrs != null) {
          final listAttr = attrs['list'];
          if (listAttr == 'checked' || listAttr == 'unchecked') {
            // Find the previous state from 'before' delta
            final wasChecked = _getCheckboxStateAtOffset(before, offset);
            if (wasChecked != null) {
              return CheckboxChangeResult(
                offset: offset,
                isChecked: listAttr == 'checked',
                wasChecked: wasChecked,
              );
            }
          }
        }
        offset += (op.length ?? 0).toInt();
      } else if (op.isInsert) {
        final data = op.data;
        offset += data is String ? data.length : 1;
      }
    }

    return null;
  }

  /// Get the checkbox state at a specific offset from a delta
  bool? _getCheckboxStateAtOffset(Delta delta, int targetOffset) {
    int offset = 0;

    for (final op in delta.toList()) {
      if (!op.isInsert) continue;

      final data = op.data;
      final length = data is String ? data.length : 1;

      if (offset == targetOffset) {
        final attrs = op.attributes;
        if (attrs != null) {
          final listAttr = attrs['list'];
          if (listAttr == 'checked') return true;
          if (listAttr == 'unchecked') return false;
        }
        break;
      }

      offset += length;
    }

    return null;
  }

  /// Find the node index for a given offset
  int? getNodeIndexAtOffset(int offset) {
    return _offsetToIndexMap?[offset];
  }

  /// Find all children of a checkbox node (recursive descendants)
  /// Children are consecutive checkbox nodes with higher indent levels
  /// until we hit a node with indent <= parent's indent, a gap, or end of list
  List<CheckboxNode> findChildren(int parentIndex, List<CheckboxNode> nodes) {
    if (parentIndex < 0 || parentIndex >= nodes.length) {
      return [];
    }

    final parent = nodes[parentIndex];
    final parentIndent = parent.indentLevel;
    final children = <CheckboxNode>[];

    // Start from the node after the parent
    for (int i = parentIndex + 1; i < nodes.length; i++) {
      final node = nodes[i];

      // Stop if there's a gap (non-checkbox content) before this node
      if (node.hasGapBefore) {
        break;
      }

      // Stop if we hit a node at same or lower indent level
      if (node.indentLevel <= parentIndent) {
        break;
      }

      // This is a descendant
      children.add(node);
    }

    return children;
  }

  /// Find the parent of a checkbox node
  /// Parent is the nearest preceding node with lower indent level (with no gap between)
  CheckboxNode? findParent(int childIndex, List<CheckboxNode> nodes) {
    if (childIndex <= 0 || childIndex >= nodes.length) {
      return null;
    }

    final child = nodes[childIndex];
    final childIndent = child.indentLevel;

    // If child has no indent, it has no parent
    if (childIndent == 0) {
      return null;
    }

    // If there's a gap before this child, it has no parent in the current hierarchy
    if (child.hasGapBefore) {
      return null;
    }

    // Search backwards for a node with lower indent
    for (int i = childIndex - 1; i >= 0; i--) {
      final node = nodes[i];

      // If we encounter a node with lower indent, that's the parent
      if (node.indentLevel < childIndent) {
        return node;
      }

      // Note: gaps between same-level siblings don't affect parent lookup,
      // we continue searching backwards until we find a lower indent node
    }

    return null;
  }

  /// Get all offsets that need to be updated when cascading down (parent checked/unchecked)
  /// Returns list of child offsets that need to be set to the same state
  List<int> getCascadeTargets(
    int toggledIndex,
    bool newState,
    List<CheckboxNode> nodes,
  ) {
    final children = findChildren(toggledIndex, nodes);

    // Filter children that need to change (not already in the target state)
    final targets = <int>[];
    for (final child in children) {
      if (child.isChecked != newState) {
        targets.add(child.offset);
      }
    }

    return targets;
  }

  /// Get all parent offsets that need to be updated when bubbling up
  /// Returns list of (offset, newState) pairs for parents that need updating
  List<({int offset, bool newState})> getBubbleTargets(
    int toggledIndex,
    bool newState,
    List<CheckboxNode> nodes,
  ) {
    final targets = <({int offset, bool newState})>[];

    // Start from the toggled node and work up
    int currentIndex = toggledIndex;

    // Safety counter to prevent infinite loop (max nesting depth)
    int iterations = 0;
    const maxIterations = 100;

    while (iterations++ < maxIterations) {
      final parent = findParent(currentIndex, nodes);
      if (parent == null) break;

      // Get all direct children of this parent (at next indent level)
      final directChildren = findChildren(
        parent.index,
        nodes,
      ).where((c) => c.indentLevel == parent.indentLevel + 1).toList();

      if (directChildren.isEmpty) break;

      if (newState) {
        // Checking: if ALL siblings are now checked, check the parent
        final allChecked = directChildren.every((c) {
          // Use updated state for the node we just toggled
          if (c.index == toggledIndex) return true;
          // Check if this child was already in our targets list (bubbled up)
          final inTargets = targets.any((t) => t.offset == c.offset);
          if (inTargets) return true;
          return c.isChecked;
        });

        if (allChecked && !parent.isChecked) {
          targets.add((offset: parent.offset, newState: true));
          currentIndex = parent.index;
        } else {
          break;
        }
      } else {
        // Unchecking: if parent was checked and ANY child is now unchecked, uncheck parent
        if (parent.isChecked) {
          targets.add((offset: parent.offset, newState: false));
          currentIndex = parent.index;
        } else {
          break;
        }
      }
    }

    return targets;
  }

  /// Apply checkbox state changes to a document
  /// Returns the number of changes applied
  int applyCheckboxChanges(
    QuillController controller,
    List<int> offsets,
    bool checked,
  ) {
    if (offsets.isEmpty) return 0;

    // Sort offsets descending to preserve positions when applying changes
    final sortedOffsets = List<int>.from(offsets)
      ..sort((a, b) => b.compareTo(a));

    final attribute = checked ? Attribute.checked : Attribute.unchecked;

    for (final offset in sortedOffsets) {
      controller.formatText(offset, 0, attribute);
    }

    // Invalidate cache after changes
    invalidateCache();

    return sortedOffsets.length;
  }
}
