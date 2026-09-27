import 'package:flutter_quill/flutter_quill.dart';
import 'package:better_keep/models/note_table.dart';
import 'package:markdown/markdown.dart' as md;

/// Utility class for converting markdown to Quill Delta format
class MarkdownConverter {
  /// Convert markdown text to Quill Delta format
  ///
  /// Returns a list of delta operations that can be used to create a Quill Document
  static List<Map<String, dynamic>> markdownToQuillDelta(String markdown) {
    final delta = <Map<String, dynamic>>[];

    // Preprocess: join multiline links [text\nmore text](url) into single line
    String processed = markdown;
    processed = processed.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)', multiLine: true),
      (m) {
        // Replace newlines in the link text with spaces
        final linkText = m.group(1)?.replaceAll('\n', ' ') ?? '';
        final linkUrl = m.group(2) ?? '';
        return '[$linkText]($linkUrl)';
      },
    );

    // Split markdown into lines and process
    final lines = processed.split(RegExp(r'\r\n?|\n'));
    final markdownDocument = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    bool inCodeBlock = false;
    String codeFence = '```';
    String codeBlockContent = '';
    bool lastWasHeader = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Check for code block fence
      if (line.trim().startsWith(inCodeBlock ? codeFence : '```') ||
          (!inCodeBlock && line.trim().startsWith('~~~'))) {
        if (!inCodeBlock) {
          // Starting a code block
          inCodeBlock = true;
          codeFence = line.trim().substring(0, 3);
          codeBlockContent = '';
          lastWasHeader = false;
        } else {
          // Ending a code block
          inCodeBlock = false;
          // Add the accumulated code block content
          if (codeBlockContent.isNotEmpty) {
            // Remove trailing newline from code content
            if (codeBlockContent.endsWith('\n')) {
              codeBlockContent = codeBlockContent.substring(
                0,
                codeBlockContent.length - 1,
              );
            }
            delta.add({'insert': codeBlockContent});
            delta.add({
              'insert': '\n',
              'attributes': {'code-block': true},
            });
          }
        }
        continue;
      }

      if (inCodeBlock) {
        // Accumulate code block content
        codeBlockContent += '$line\n';
        continue;
      }

      final table = _parseTable(lines, i, markdownDocument);
      if (table != null) {
        delta.add({
          'insert': {NoteTableData.type: table.toJson()},
        });
        delta.add({'insert': '\n'});
        // Each data row uses one source line; the delimiter adds one more.
        i += table.rows;
        lastWasHeader = false;
        continue;
      }

      final attributes = _getLineAttributes(line);
      final text = _stripMarkdownSyntax(line);
      final isHeader = attributes != null && attributes.containsKey('header');

      // Skip all empty/whitespace-only lines after a header
      if (lastWasHeader && text.trim().isEmpty) {
        // Keep lastWasHeader true to continue skipping empty lines
        continue;
      }

      lastWasHeader = isHeader;

      if (text.isNotEmpty) {
        // Process inline formatting
        _addFormattedText(delta, text);
      }

      // Add newline with block attributes
      if (attributes != null) {
        delta.add({'insert': '\n', 'attributes': attributes});
      } else {
        delta.add({'insert': '\n'});
      }
    }

    // Handle unclosed code block
    if (inCodeBlock && codeBlockContent.isNotEmpty) {
      if (codeBlockContent.endsWith('\n')) {
        codeBlockContent = codeBlockContent.substring(
          0,
          codeBlockContent.length - 1,
        );
      }
      delta.add({'insert': codeBlockContent});
      delta.add({
        'insert': '\n',
        'attributes': {'code-block': true},
      });
    }

    return delta;
  }

  /// Let the existing Markdown parser handle escaped pipes, optional outer
  /// pipes, alignment, and incomplete rows without changing other paste blocks.
  static NoteTableData? _parseTable(
    List<String> lines,
    int start,
    md.Document document,
  ) {
    if (start + 1 >= lines.length) return null;
    const syntax = md.TableSyntax();
    final probe = md.BlockParser([
      md.Line(lines[start]),
      md.Line(lines[start + 1]),
    ], document);
    if (!syntax.canParse(probe)) return null;
    final parser = md.BlockParser(
      lines.skip(start).map(md.Line.new).toList(),
      document,
    );
    final node = syntax.parse(parser);
    if (node is! md.Element) return null;
    final rows = [
      for (final section in node.children!.cast<md.Element>())
        ...section.children!.cast<md.Element>(),
    ];
    final columns = rows.first.children!.length;
    // Keep oversized source as text instead of silently losing cells.
    if (rows.length > NoteTableData.maxDimension ||
        columns > NoteTableData.maxDimension) {
      return null;
    }
    final cells = <String, List<dynamic>>{};
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r].children!.cast<md.Element>();
      for (var c = 0; c < row.length; c++) {
        final cell = row[c];
        final delta = <Map<String, dynamic>>[];
        _addTableInline(
          delta,
          document.parseInline(cell.textContent),
          r == 0 ? {'bold': true} : {},
        );
        final alignment = cell.attributes['align'];
        delta.add({
          'insert': '\n',
          if (alignment != null) 'attributes': {'align': alignment},
        });
        if (delta.length > 1 || alignment != null) cells['$r:$c'] = delta;
      }
    }
    return NoteTableData(rows: rows.length, columns: columns, cells: cells);
  }

  static void _addTableInline(
    List<Map<String, dynamic>> delta,
    List<md.Node> nodes,
    Map<String, dynamic> attributes,
  ) {
    for (final node in nodes) {
      if (node is md.Text) {
        delta.add({
          'insert': node.text,
          if (attributes.isNotEmpty) 'attributes': attributes,
        });
      } else if (node is md.Element) {
        final next = {...attributes};
        switch (node.tag) {
          case 'strong':
            next['bold'] = true;
          case 'em':
            next['italic'] = true;
          case 'code':
            next['code'] = true;
          case 'del':
            next['strike'] = true;
          case 'a':
            next['link'] = node.attributes['href'];
        }
        if (node.tag == 'img') {
          next['link'] = node.attributes['src'];
          _addTableInline(delta, [md.Text(node.attributes['alt'] ?? '')], next);
        } else {
          _addTableInline(delta, node.children ?? [], next);
        }
      }
    }
  }

  /// Create a Quill Document from markdown text
  static Document markdownToDocument(String markdown) {
    final deltaOps = markdownToQuillDelta(markdown);
    // Ensure delta ends with a newline
    if (deltaOps.isEmpty ||
        (deltaOps.last['insert'] != '\n' &&
            !(deltaOps.last['insert'] is String &&
                (deltaOps.last['insert'] as String).endsWith('\n')))) {
      deltaOps.add({'insert': '\n'});
    }
    return Document.fromJson(deltaOps);
  }

  /// Get block-level attributes from a markdown line
  static Map<String, dynamic>? _getLineAttributes(String line) {
    // Headers
    if (line.startsWith('# ')) {
      return {'header': 1};
    } else if (line.startsWith('## ')) {
      return {'header': 2};
    } else if (line.startsWith('### ')) {
      return {'header': 3};
    }

    // Checkboxes - must check BEFORE bullet lists since they start with - or *
    if (RegExp(r'^\s*[-*+]\s*\[\s*\]\s').hasMatch(line)) {
      return {'list': 'unchecked'};
    }
    if (RegExp(r'^\s*[-*+]\s*\[[xX]\]\s').hasMatch(line)) {
      return {'list': 'checked'};
    }

    // Lists
    if (RegExp(r'^\s*[-*+]\s').hasMatch(line)) {
      return {'list': 'bullet'};
    }
    if (RegExp(r'^\s*\d+\.\s').hasMatch(line)) {
      return {'list': 'ordered'};
    }

    // Blockquote
    if (line.startsWith('> ')) {
      return {'blockquote': true};
    }

    return null;
  }

  /// Strip markdown syntax from a line, leaving just the text
  static String _stripMarkdownSyntax(String line) {
    String text = line;

    // Remove header markers
    text = text.replaceFirst(RegExp(r'^#{1,6}\s+'), '');

    // Remove checkbox markers (must be before list markers)
    // Matches: - [ ] text, * [x] text, + [ ] text (with optional spaces)
    text = text.replaceFirst(RegExp(r'^\s*[-*+]\s*\[[xX ]\]\s+'), '');

    // Remove list markers
    text = text.replaceFirst(RegExp(r'^\s*[-*+]\s'), '');
    text = text.replaceFirst(RegExp(r'^\s*\d+\.\s'), '');

    // Remove blockquote marker
    text = text.replaceFirst(RegExp(r'^>\s*'), '');

    return text;
  }

  /// Add text with inline formatting to delta
  static void _addFormattedText(List<Map<String, dynamic>> delta, String text) {
    final segments = _parseInlineFormatting(text);

    for (final segment in segments) {
      if (segment.attributes != null && segment.attributes!.isNotEmpty) {
        delta.add({'insert': segment.text, 'attributes': segment.attributes});
      } else {
        delta.add({'insert': segment.text});
      }
    }
  }

  /// Parse inline markdown formatting
  static List<_TextSegment> _parseInlineFormatting(String text) {
    final segments = <_TextSegment>[];
    String remaining = text;

    while (remaining.isNotEmpty) {
      // Try to match bold (**text** or __text__)
      final boldMatch = RegExp(
        r'\*\*(.+?)\*\*|__(.+?)__',
      ).firstMatch(remaining);

      // Try to match italic (*text* or _text_)
      final italicMatch = RegExp(
        r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)|(?<!_)_(?!_)(.+?)(?<!_)_(?!_)',
      ).firstMatch(remaining);

      // Try to match inline code (`code`)
      final codeMatch = RegExp(r'`([^`]+)`').firstMatch(remaining);

      // Try to match links [text](url)
      final linkMatch = RegExp(
        r'\[([^\]]+)\]\(([^)\s]+)\)',
      ).firstMatch(remaining);

      // Find earliest match
      Match? earliest;
      String type = '';

      for (final entry in [
        (boldMatch, 'bold'),
        (italicMatch, 'italic'),
        (codeMatch, 'code'),
        (linkMatch, 'link'),
      ]) {
        if (entry.$1 != null) {
          if (earliest == null || entry.$1!.start < earliest.start) {
            earliest = entry.$1;
            type = entry.$2;
          }
        }
      }

      if (earliest == null) {
        // No more formatting, add rest as plain text
        if (remaining.isNotEmpty) {
          segments.add(_TextSegment(text: remaining));
        }
        break;
      }

      // Add text before the match as plain
      if (earliest.start > 0) {
        segments.add(
          _TextSegment(text: remaining.substring(0, earliest.start)),
        );
      }

      // Add formatted segment
      switch (type) {
        case 'bold':
          final content = earliest.group(1) ?? earliest.group(2) ?? '';
          segments.add(_TextSegment(text: content, attributes: {'bold': true}));
          break;
        case 'italic':
          final content = earliest.group(1) ?? earliest.group(2) ?? '';
          segments.add(
            _TextSegment(text: content, attributes: {'italic': true}),
          );
          break;
        case 'code':
          final content = earliest.group(1) ?? '';
          segments.add(_TextSegment(text: content, attributes: {'code': true}));
          break;
        case 'link':
          final linkText = earliest.group(1) ?? '';
          final linkUrl = earliest.group(2) ?? '';
          segments.add(
            _TextSegment(text: linkText, attributes: {'link': linkUrl}),
          );
          break;
      }

      remaining = remaining.substring(earliest.end);
    }

    return segments.isEmpty ? [_TextSegment(text: text)] : segments;
  }
}

/// A text segment with optional formatting attributes
class _TextSegment {
  final String text;
  final Map<String, dynamic>? attributes;

  _TextSegment({required this.text, this.attributes});
}
