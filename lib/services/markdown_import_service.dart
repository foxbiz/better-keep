import 'dart:convert';

import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

/// Service for importing markdown files as notes.
/// Handles:
/// - Converting markdown to Quill Delta format
/// - Downloading remote media (https://) to local storage
/// - Decoding base64 media to local storage
/// - Normalizing headers (only first H1, rest become H2+)
class MarkdownImportService {
  static const int _maxImageSize = 500 * 1024; // 500KB max for images
  static const Duration _downloadTimeout = Duration(seconds: 30);

  /// Import markdown content as a note
  static Future<Note> importMarkdown({
    required String title,
    required String markdownContent,
  }) async {
    AppLogger.log('[MarkdownImport] Starting markdown import: $title');

    // Extract title from first H1 in content, or use provided title as fallback
    final extractedTitle = _extractTitleFromMarkdown(markdownContent) ?? title;

    // Create a new note
    final note = Note(title: extractedTitle);

    // Process the markdown (HTML conversion, header normalization, etc.)
    final processedContent = await _processMarkdown(markdownContent, note);

    // Process images for inline embedding
    final imageResult = await _processImagesForInline(processedContent);

    // Convert to Quill Delta format with inline images
    final delta = _markdownToQuillDelta(
      imageResult.markdown,
      imageResult.imageMap,
    );
    note.content = json.encode(delta);
    note.plainText = _extractPlainText(imageResult.markdown);

    // Save the note
    await note.save();

    AppLogger.log('[MarkdownImport] Successfully imported note: ${note.id}');
    return note;
  }

  /// Extract title from first H1 in markdown content
  static String? _extractTitleFromMarkdown(String markdown) {
    final lines = markdown.split('\n');
    for (final line in lines) {
      final h1Match = RegExp(r'^#\s+(.+)$').firstMatch(line.trim());
      if (h1Match != null) {
        return h1Match.group(1)?.trim();
      }
    }
    return null;
  }

  /// Import plain text content as a note
  static Future<Note> importPlainText({
    required String title,
    required String textContent,
  }) async {
    AppLogger.log('[MarkdownImport] Starting plain text import: $title');

    // Create Quill Delta for plain text
    final delta = <Map<String, dynamic>>[];

    // Add title as header
    if (title.isNotEmpty) {
      delta.add({'insert': title});
      delta.add({
        'insert': '\n',
        'attributes': {'header': 1},
      });
    }

    // Add content
    if (textContent.isNotEmpty) {
      delta.add({'insert': textContent});
    }

    // Always end with newline
    delta.add({'insert': '\n'});

    // Create and save the note
    final note = Note(
      title: title,
      content: json.encode(delta),
      plainText: textContent,
    );
    await note.save();

    AppLogger.log('[MarkdownImport] Successfully imported note: ${note.id}');
    return note;
  }

  /// Process markdown content:
  /// - Strip/convert HTML to text
  /// - Download/decode media
  /// - Normalize headers
  static Future<String> _processMarkdown(String markdown, Note note) async {
    String processed = markdown;

    // Convert HTML tags to markdown or strip them
    processed = _convertHtmlToText(processed);

    // Normalize headers first
    processed = _normalizeHeaders(processed);

    // Process images
    processed = await _processImages(processed, note);

    // Process audio (if any markdown audio embeds)
    processed = await _processAudio(processed, note);

    return processed;
  }

  /// Convert common HTML tags to markdown or strip them
  /// Note: <img> tags are preserved and handled separately by _processImagesForInline
  static String _convertHtmlToText(String html) {
    String result = html;

    // First, preserve <a><img></a> patterns as a unit (multiline support)
    // These will be processed later by _processImagesForInline
    final linkedImgPreserveMap = <String, String>{};
    int linkedImgIdx = 0;
    result = result.replaceAllMapped(
      RegExp(
        r'''<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>[\s\S]*?<img\s[^>]*src\s*=\s*["']([^"']+)["'][^>]*/?>[\s\S]*?</a>''',
        caseSensitive: false,
      ),
      (m) {
        final marker = '{{PRESERVED_LINKED_IMG_$linkedImgIdx}}';
        // Store just the img tag with src - we'll extract the image URL in _processImagesForInline
        linkedImgPreserveMap[marker] = '<img src="${m.group(2)}">';
        linkedImgIdx++;
        return marker;
      },
    );

    // Preserve standalone <img> tags
    // They will be processed later by _processImagesForInline
    final imgPreserveMap = <String, String>{};
    int imgIdx = 0;
    result = result.replaceAllMapped(
      RegExp(
        r'''<img\s+[^>]*src\s*=\s*["']?([^"'\s>]+)["']?[^>]*\/?>''',
        caseSensitive: false,
      ),
      (m) {
        final marker = '{{PRESERVED_IMG_$imgIdx}}';
        imgPreserveMap[marker] = m.group(0)!;
        imgIdx++;
        return marker;
      },
    );

    // Convert common HTML tags to markdown equivalents
    result = result.replaceAllMapped(
      RegExp(r'<b>([^<]*)</b>', caseSensitive: false),
      (m) => '**${m.group(1)}**',
    );
    result = result.replaceAllMapped(
      RegExp(r'<strong>([^<]*)</strong>', caseSensitive: false),
      (m) => '**${m.group(1)}**',
    );
    result = result.replaceAllMapped(
      RegExp(r'<i>([^<]*)</i>', caseSensitive: false),
      (m) => '*${m.group(1)}*',
    );
    result = result.replaceAllMapped(
      RegExp(r'<em>([^<]*)</em>', caseSensitive: false),
      (m) => '*${m.group(1)}*',
    );
    result = result.replaceAllMapped(
      RegExp(r'<code>([^<]*)</code>', caseSensitive: false),
      (m) => '`${m.group(1)}`',
    );

    // Convert anchor tags with various attribute orders
    // Handle: <a href="url">text</a>, <a class="..." href="url">text</a>, etc.
    result = result.replaceAllMapped(
      RegExp(
        r'''<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([^<]*)</a>''',
        caseSensitive: false,
      ),
      (m) => '[${m.group(2)}](${m.group(1)})',
    );

    // Convert line breaks
    result = result.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );

    // Convert paragraphs to double newlines
    result = result.replaceAll(
      RegExp(r'</p>\s*<p>', caseSensitive: false),
      '\n\n',
    );
    result = result.replaceAll(RegExp(r'</?p>', caseSensitive: false), '');

    // Convert headers
    for (int i = 6; i >= 1; i--) {
      result = result.replaceAllMapped(
        RegExp('<h$i[^>]*>([^<]*)</h$i>', caseSensitive: false),
        (m) => '${'#' * i} ${m.group(1)}\n',
      );
    }

    // Convert lists
    result = result.replaceAllMapped(
      RegExp(r'<li[^>]*>([^<]*)</li>', caseSensitive: false),
      (m) => '- ${m.group(1)}\n',
    );
    result = result.replaceAll(
      RegExp(r'</?[uo]l[^>]*>', caseSensitive: false),
      '',
    );

    // Strip remaining HTML tags (but not our preserved markers)
    result = result.replaceAll(RegExp(r'<[^>]+>'), '');

    // Restore preserved <a><img></a> patterns (as just img tags)
    linkedImgPreserveMap.forEach((marker, original) {
      result = result.replaceAll(marker, original);
    });

    // Restore preserved <img> tags
    imgPreserveMap.forEach((marker, original) {
      result = result.replaceAll(marker, original);
    });

    // Decode HTML entities
    result = result
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');

    return result;
  }

  /// Normalize headers: only first H1 stays as H1, rest become H2+
  static String _normalizeHeaders(String markdown) {
    final lines = markdown.split('\n');
    bool foundFirstH1 = false;
    int h1Count = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Check for ATX-style headers (# Header)
      final h1Match = RegExp(r'^#\s+(.*)$').firstMatch(line);
      if (h1Match != null) {
        if (!foundFirstH1) {
          foundFirstH1 = true;
        } else {
          // Convert to H2
          h1Count++;
          lines[i] = '## ${h1Match.group(1)}';
        }
      }
    }

    if (h1Count > 0) {
      AppLogger.log('[MarkdownImport] Normalized $h1Count H1 headers to H2');
    }

    return lines.join('\n');
  }

  /// Process images in markdown: keep URLs for inline embedding
  /// Returns the markdown with image placeholders and a map of placeholder -> URL
  /// Handles both markdown syntax ![alt](url) and HTML <img> tags
  static Future<_ImageProcessResult> _processImagesForInline(
    String markdown,
  ) async {
    final Map<String, String> imageMap = {};
    final Map<String, String> altTextMap = {};
    int imageIndex = 0;
    String result = markdown;

    // 1. FIRST: Process linked images: [![alt](image_url)](link_url)
    // This must come before regular image processing to avoid partial matches
    final linkedImageRegex = RegExp(
      r'\[!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\]\(([^)]+)\)',
    );
    var matches = linkedImageRegex.allMatches(result).toList();

    // Process in reverse order to preserve string positions
    for (int i = matches.length - 1; i >= 0; i--) {
      final match = matches[i];
      final altText = match.group(1) ?? '';
      final imageUrl = match.group(2) ?? '';
      // link_url is match.group(3) - we discard the link, just keep the image

      if (_isValidImageUrl(imageUrl)) {
        final placeholder = '{{IMG_$imageIndex}}';
        imageMap[placeholder] = imageUrl;
        altTextMap[placeholder] = altText;
        imageIndex++;
        result = result.replaceRange(match.start, match.end, placeholder);
      } else {
        // Invalid image URL - keep just the alt text
        result = result.replaceRange(
          match.start,
          match.end,
          altText.isNotEmpty ? altText : '',
        );
      }
    }

    // 2. Process HTML anchor tags with img inside: <a href="..."><img src="..."></a>
    // Handle multiline format with newlines/whitespace between tags
    final htmlLinkedImgRegex = RegExp(
      r'''<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>[\s\S]*?<img\s[^>]*src\s*=\s*["']([^"']+)["'][^>]*/?>[\s\S]*?</a>''',
      caseSensitive: false,
    );
    matches = htmlLinkedImgRegex.allMatches(result).toList();

    for (int i = matches.length - 1; i >= 0; i--) {
      final match = matches[i];
      // link is match.group(1) - discard the link
      final imageUrl = match.group(2) ?? '';

      if (_isValidImageUrl(imageUrl)) {
        final placeholder = '{{IMG_$imageIndex}}';
        imageMap[placeholder] = imageUrl;
        imageIndex++;
        result = result.replaceRange(match.start, match.end, placeholder);
      } else {
        result = result.replaceRange(match.start, match.end, '');
      }
    }

    // 3. Process markdown-style linked img tags: [<img src="url">](link_url)
    final linkedImgTagRegex = RegExp(
      r'''\[<img\s+[^>]*src\s*=["']?([^"'\s>]+)["']?[^>]*/?>\]\(([^)]+)\)''',
      caseSensitive: false,
    );
    matches = linkedImgTagRegex.allMatches(result).toList();

    for (int i = matches.length - 1; i >= 0; i--) {
      final match = matches[i];
      final imageUrl = match.group(1) ?? '';
      // link_url is match.group(2) - discard the link

      if (_isValidImageUrl(imageUrl)) {
        final placeholder = '{{IMG_$imageIndex}}';
        imageMap[placeholder] = imageUrl;
        imageIndex++;
        result = result.replaceRange(match.start, match.end, placeholder);
      } else {
        result = result.replaceRange(match.start, match.end, '');
      }
    }

    // 4. Process regular markdown image syntax: ![alt](url)
    final mdImageRegex = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
    matches = mdImageRegex.allMatches(result).toList();

    // Process in reverse order to preserve string positions
    for (int i = matches.length - 1; i >= 0; i--) {
      final match = matches[i];
      final altText = match.group(1) ?? '';
      final url = match.group(2) ?? '';

      if (_isValidImageUrl(url)) {
        final placeholder = '{{IMG_$imageIndex}}';
        imageMap[placeholder] = url;
        altTextMap[placeholder] = altText;
        imageIndex++;
        result = result.replaceRange(match.start, match.end, placeholder);
      } else {
        // Local/unsupported URL - keep alt text if available
        result = result.replaceRange(
          match.start,
          match.end,
          altText.isNotEmpty ? altText : '',
        );
      }
    }

    // 2. Process HTML <img> tags with src attribute
    // Matches: <img src="url">, <img src='url'>, <img src=url>
    final imgTagRegex = RegExp(
      r'''<img\s+[^>]*src\s*=\s*["']?([^"'\s>]+)["']?[^>]*\/?>''',
      caseSensitive: false,
    );
    matches = imgTagRegex.allMatches(result).toList();

    for (int i = matches.length - 1; i >= 0; i--) {
      final match = matches[i];
      final url = match.group(1) ?? '';

      if (_isValidImageUrl(url)) {
        final placeholder = '{{IMG_$imageIndex}}';
        imageMap[placeholder] = url;
        imageIndex++;
        result = result.replaceRange(match.start, match.end, placeholder);
      } else {
        // Remove invalid img tag
        result = result.replaceRange(match.start, match.end, '');
      }
    }

    AppLogger.log('[MarkdownImport] Found ${imageMap.length} images to embed');
    return _ImageProcessResult(markdown: result, imageMap: imageMap);
  }

  /// Check if URL is a valid image URL (http, https, or data URI)
  static bool _isValidImageUrl(String url) {
    if (url.isEmpty) return false;
    return url.startsWith('http://') ||
        url.startsWith('https://') ||
        url.startsWith('data:image/');
  }

  /// Process images in markdown: download remote, decode base64 (legacy - for attachments)
  static Future<String> _processImages(String markdown, Note note) async {
    // For now, we don't download images as attachments anymore
    // Images are handled inline via _processImagesForInline
    return markdown;
  }

  /// Process audio embeds in markdown
  static Future<String> _processAudio(String markdown, Note note) async {
    // Match HTML5 audio tags: <audio src="...">
    final audioRegex = RegExp(
      r'''<audio[^>]*src=["']([^"']+)["'][^>]*>.*?</audio>''',
      caseSensitive: false,
    );
    final matches = audioRegex.allMatches(markdown).toList();

    String result = markdown;
    for (int i = matches.length - 1; i >= 0; i--) {
      final match = matches[i];
      final url = match.group(1) ?? '';

      try {
        final localPath = await _downloadOrDecodeMedia(
          url: url,
          note: note,
          type: 'audio',
        );

        if (localPath != null) {
          // Add as note attachment
          _addAudioToNote(note, localPath);
          result = result.replaceRange(
            match.start,
            match.end,
            '[Audio attached]',
          );
        } else {
          result = result.replaceRange(
            match.start,
            match.end,
            '[Audio (failed to load)]',
          );
        }
      } catch (e) {
        AppLogger.error('[MarkdownImport] Error processing audio: $url', e);
        result = result.replaceRange(match.start, match.end, '[Audio (error)]');
      }
    }

    return result;
  }

  /// Download remote URL or decode base64 data to local storage
  static Future<String?> _downloadOrDecodeMedia({
    required String url,
    required Note note,
    required String type,
  }) async {
    if (url.isEmpty) return null;

    final fs = await fileSystem();
    final documentDir = await fs.documentDir;

    try {
      Uint8List bytes;
      String extension;

      if (url.startsWith('data:')) {
        // Base64 data URL
        final result = _decodeDataUrl(url);
        if (result == null) return null;
        bytes = result.bytes;
        extension = result.extension;
        AppLogger.log('[MarkdownImport] Decoded base64 $type');
      } else if (url.startsWith('http://') || url.startsWith('https://')) {
        // Remote URL - download
        final result = await _downloadFromUrl(url);
        if (result == null) return null;
        bytes = result.bytes;
        extension = result.extension;
        AppLogger.log('[MarkdownImport] Downloaded $type from $url');
      } else {
        // Unsupported URL scheme
        AppLogger.log('[MarkdownImport] Unsupported URL scheme: $url');
        return null;
      }

      // Compress images
      if (type == 'image') {
        bytes = await _compressImage(bytes);
      }

      // Save to local storage
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final folder = type == 'audio' ? 'recordings' : 'images';
      final filePath = path.join(documentDir, folder, '$timestamp$extension');

      await writeEncryptedBytes(filePath, bytes);
      AppLogger.log('[MarkdownImport] Saved $type to: $filePath');

      return filePath;
    } catch (e) {
      AppLogger.error('[MarkdownImport] Failed to process media: $url', e);
      return null;
    }
  }

  /// Decode a data: URL (base64)
  static _MediaResult? _decodeDataUrl(String dataUrl) {
    try {
      // Format: data:image/png;base64,iVBORw0KGgo...
      final regex = RegExp(r'^data:([^;]+);base64,(.+)$');
      final match = regex.firstMatch(dataUrl);
      if (match == null) return null;

      final mimeType = match.group(1) ?? '';
      final base64Data = match.group(2) ?? '';

      final bytes = base64Decode(base64Data);
      final extension = _mimeToExtension(mimeType);

      return _MediaResult(bytes: bytes, extension: extension);
    } catch (e) {
      AppLogger.error('[MarkdownImport] Failed to decode data URL', e);
      return null;
    }
  }

  /// Download from a URL
  static Future<_MediaResult?> _downloadFromUrl(String url) async {
    try {
      final response = await http.get(Uri.parse(url)).timeout(_downloadTimeout);

      if (response.statusCode != 200) {
        AppLogger.log(
          '[MarkdownImport] Download failed with status: ${response.statusCode}',
        );
        return null;
      }

      final bytes = response.bodyBytes;
      final contentType = response.headers['content-type'] ?? '';
      String extension = _mimeToExtension(contentType);

      // Fallback: try to get extension from URL
      if (extension == '.bin') {
        final urlExt = path.extension(Uri.parse(url).path);
        if (urlExt.isNotEmpty) {
          extension = urlExt;
        }
      }

      return _MediaResult(bytes: bytes, extension: extension);
    } catch (e) {
      AppLogger.error('[MarkdownImport] Download failed: $url', e);
      return null;
    }
  }

  /// Convert MIME type to file extension
  static String _mimeToExtension(String mimeType) {
    final mime = mimeType.toLowerCase().split(';').first.trim();
    switch (mime) {
      case 'image/png':
        return '.png';
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'audio/mpeg':
      case 'audio/mp3':
        return '.mp3';
      case 'audio/wav':
      case 'audio/wave':
        return '.wav';
      case 'audio/ogg':
        return '.ogg';
      case 'audio/m4a':
      case 'audio/mp4':
        return '.m4a';
      default:
        return '.bin';
    }
  }

  /// Compress an image to target size
  static Future<Uint8List> _compressImage(Uint8List bytes) async {
    // Skip compression on web
    if (kIsWeb) return bytes;

    if (bytes.length <= _maxImageSize) {
      // Light compression even for small images
      try {
        return await FlutterImageCompress.compressWithList(bytes, quality: 90);
      } catch (e) {
        return bytes;
      }
    }

    // Progressive compression
    int quality = 85;
    int minDim = 1920;
    Uint8List compressed = bytes;

    while (quality >= 50) {
      try {
        compressed = await FlutterImageCompress.compressWithList(
          bytes,
          quality: quality,
          minWidth: minDim,
          minHeight: minDim,
        );

        if (compressed.length <= _maxImageSize) {
          return compressed;
        }
      } catch (e) {
        break;
      }

      quality -= 10;
    }

    // Try reducing dimensions
    minDim = 1280;
    quality = 70;
    while (minDim >= 640) {
      try {
        compressed = await FlutterImageCompress.compressWithList(
          bytes,
          quality: quality,
          minWidth: minDim,
          minHeight: minDim,
        );

        if (compressed.length <= _maxImageSize) {
          return compressed;
        }
      } catch (e) {
        break;
      }

      minDim -= 320;
    }

    return compressed;
  }

  /// Add audio to the note as an attachment
  static void _addAudioToNote(Note note, String localPath) {
    final recording = NoteRecording(src: localPath);
    final attachment = NoteAttachment.audio(recording);
    note.addAttachmentDirectly(attachment);
    AppLogger.log('[MarkdownImport] Added audio attachment');
  }

  /// Convert processed markdown to Quill Delta format with inline images
  static List<Map<String, dynamic>> _markdownToQuillDelta(
    String markdown,
    Map<String, String> imageMap,
  ) {
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
    final lines = processed.split('\n');
    bool inCodeBlock = false;
    String codeBlockContent = '';
    bool lastWasHeader = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Check for code block fence
      if (line.trim().startsWith('```')) {
        if (!inCodeBlock) {
          // Starting a code block
          inCodeBlock = true;
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
        // Process inline formatting and images
        _addFormattedTextWithImages(delta, text, imageMap);
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

  /// Add text with inline formatting and image embeds to delta
  static void _addFormattedTextWithImages(
    List<Map<String, dynamic>> delta,
    String text,
    Map<String, String> imageMap,
  ) {
    // Check if text contains image placeholders
    final placeholderRegex = RegExp(r'\{\{IMG_\d+\}\}');

    if (!placeholderRegex.hasMatch(text)) {
      // No images, just add formatted text
      _addFormattedText(delta, text);
      return;
    }

    // Split text by image placeholders and process each segment
    String remaining = text;
    while (remaining.isNotEmpty) {
      final match = placeholderRegex.firstMatch(remaining);

      if (match == null) {
        // No more placeholders, add remaining text
        if (remaining.isNotEmpty) {
          _addFormattedText(delta, remaining);
        }
        break;
      }

      // Add text before the placeholder
      if (match.start > 0) {
        _addFormattedText(delta, remaining.substring(0, match.start));
      }

      // Add the image embed
      final placeholder = match.group(0)!;
      final imageUrl = imageMap[placeholder];
      if (imageUrl != null) {
        delta.add({
          'insert': {'image': imageUrl},
        });
      }

      remaining = remaining.substring(match.end);
    }
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

    // Code block (simplified - just treat as regular text for now)

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
    // Simple approach: parse inline formatting
    // For now, just add as plain text with basic formatting detection

    // Match bold, italic, code, links
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

      // Try to match links [text](url) - text can span multiple lines
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

  /// Extract plain text from processed markdown
  static String _extractPlainText(String markdown) {
    String text = markdown;

    // Remove markdown formatting
    text = text.replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1');
    text = text.replaceAll(RegExp(r'__(.+?)__'), r'$1');
    text = text.replaceAll(RegExp(r'\*(.+?)\*'), r'$1');
    text = text.replaceAll(RegExp(r'_(.+?)_'), r'$1');
    text = text.replaceAll(RegExp(r'`([^`]+)`'), r'$1');
    text = text.replaceAll(RegExp(r'\[([^\]]+)\]\([^)]+\)'), r'$1');
    text = text.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    text = text.replaceAll(RegExp(r'^\s*[-*+]\s', multiLine: true), '');
    text = text.replaceAll(RegExp(r'^\s*\d+\.\s', multiLine: true), '');
    text = text.replaceAll(RegExp(r'^>\s*', multiLine: true), '');

    return text.trim();
  }
}

/// Result of decoding/downloading media
class _MediaResult {
  final Uint8List bytes;
  final String extension;

  _MediaResult({required this.bytes, required this.extension});
}

/// Result of processing images for inline embedding
class _ImageProcessResult {
  final String markdown;
  final Map<String, String> imageMap;

  _ImageProcessResult({required this.markdown, required this.imageMap});
}

/// A text segment with optional formatting attributes
class _TextSegment {
  final String text;
  final Map<String, dynamic>? attributes;

  _TextSegment({required this.text, this.attributes});
}
