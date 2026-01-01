import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/share_link.dart';
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/note_share_service.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Share type options
enum _ShareType { text, markdown, link }

/// First dialog: Simple share type picker
class _ShareTypePickerDialog extends StatelessWidget {
  final Note note;

  const _ShareTypePickerDialog({required this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Share Note'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Note preview
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  note.title?.isNotEmpty == true
                      ? note.title!
                      : 'Untitled Note',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (note.plainText?.isNotEmpty == true) ...[
                  const SizedBox(height: 4),
                  Text(
                    note.plainText!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Share options
          _ShareOptionTile(
            icon: Icons.text_snippet_outlined,
            title: 'Share as Text',
            subtitle: 'Plain text content',
            onTap: () => Navigator.of(context).pop(_ShareType.text),
          ),
          const SizedBox(height: 8),
          _ShareOptionTile(
            icon: Icons.code,
            title: 'Share as Markdown',
            subtitle: 'Formatted with markdown syntax',
            onTap: () => Navigator.of(context).pop(_ShareType.markdown),
          ),
          const SizedBox(height: 8),
          _ShareOptionTile(
            icon: Icons.link,
            title: 'Create Secure Link',
            subtitle: 'Encrypted link with access approval',
            onTap: () => Navigator.of(context).pop(_ShareType.link),
            isPrimary: true,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Tile widget for share options
class _ShareOptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isPrimary;

  const _ShareOptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: isPrimary
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isPrimary
                      ? theme.colorScheme.primary.withValues(alpha: 0.1)
                      : theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 24,
                  color: isPrimary
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Second dialog: Secure link options
class _SecureLinkDialog extends StatefulWidget {
  final Note note;

  const _SecureLinkDialog({required this.note});

  @override
  State<_SecureLinkDialog> createState() => _SecureLinkDialogState();
}

class _SecureLinkDialogState extends State<_SecureLinkDialog> {
  bool _isLoading = true;
  bool _isCreatingLink = false;
  ShareLinkResult? _shareResult;
  List<ShareLink> _existingShares = [];
  Map<String, String?> _shareUrls = {}; // shareId -> url
  String? _error;

  // Share options
  ShareDuration _selectedDuration = ShareDuration.oneDay;
  final bool _allowModification = false;
  bool _includeAttachments = true;

  @override
  void initState() {
    super.initState();
    _loadExistingShares();
  }

  Future<void> _loadExistingShares() async {
    final noteId = widget.note.id?.toString() ?? '';
    if (noteId.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }

    final shares = await NoteShareService().getExistingSharesForNote(noteId);
    final urls = <String, String?>{};

    for (final share in shares) {
      // Try to get the stored URL directly
      var url = await NoteShareService().getStoredShareUrl(share.id);
      // Fallback to reconstructing from key if URL not stored
      url ??= await NoteShareService().getFullShareUrl(share.id);
      urls[share.id] = url;
    }

    if (mounted) {
      setState(() {
        _existingShares = shares;
        _shareUrls = urls;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    String title;
    if (_shareResult != null) {
      title = 'Link Created';
    } else if (_existingShares.isNotEmpty) {
      title = 'Active Links (${_existingShares.length})';
    } else {
      title = 'Secure Link';
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 320,
            child: _isLoading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : _shareResult != null
                ? _buildShareLinkSuccess(theme)
                : _existingShares.isNotEmpty
                ? _buildExistingSharesList(theme)
                : _buildLinkOptions(theme),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_shareResult != null),
            child: Text(_shareResult != null ? 'Done' : 'Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildExistingSharesList(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // List of existing shares
        ..._existingShares.map((share) => _buildShareItem(theme, share)),

        const SizedBox(height: 16),

        // Create new link button
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _existingShares = [];
                _shareUrls = {};
              });
            },
            icon: const Icon(Icons.add_link, size: 18),
            label: const Text('Create New Link'),
          ),
        ),
      ],
    );
  }

  Widget _buildShareItem(ThemeData theme, ShareLink share) {
    final url = _shareUrls[share.id];
    final expiresAt = share.expiresAt;
    final now = DateTime.now();
    final diff = expiresAt.difference(now);

    String expiryText;
    if (diff.inDays > 0) {
      expiryText = '${diff.inDays}d';
    } else if (diff.inHours > 0) {
      expiryText = '${diff.inHours}h';
    } else if (diff.inMinutes > 0) {
      expiryText = '${diff.inMinutes}m';
    } else {
      expiryText = 'soon';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: url != null
              ? theme.colorScheme.outline.withValues(alpha: 0.5)
              : theme.colorScheme.error.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row with expiry and revoke button
          Row(
            children: [
              Icon(
                url != null ? Icons.link : Icons.link_off,
                size: 16,
                color: url != null
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  share.id,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  expiryText,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => _revokeShare(share),
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: theme.colorScheme.error,
                ),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Revoke link',
              ),
            ],
          ),

          if (url != null) ...[
            const SizedBox(height: 8),
            // Copy and Share buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _copyUrl(url),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _shareUrl(url),
                    icon: const Icon(Icons.share, size: 16),
                    label: const Text('Share'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              'Link not available (created on another device)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _revokeShare(ShareLink share) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke Link?'),
        content: const Text(
          'This will permanently disable this share link. Anyone with the link will no longer be able to access the note.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      try {
        await NoteShareService().revokeShareLink(share.id);
        // Remove from local list
        setState(() {
          _existingShares.removeWhere((s) => s.id == share.id);
          _shareUrls.remove(share.id);
        });
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Link revoked')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to revoke: $e')));
        }
      }
    }
  }

  void _copyUrl(String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Link copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _shareUrl(String url) {
    SharePlus.instance.share(
      ShareParams(
        text: url,
        title: 'Shared Note: ${widget.note.title ?? 'Untitled'}',
      ),
    );
  }

  Widget _buildLinkOptions(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Expires after
        Text(
          'Link expires after',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: ShareDuration.values.map((duration) {
            final isSelected = _selectedDuration == duration;
            return ChoiceChip(
              label: Text(duration.label),
              selected: isSelected,
              onSelected: (selected) {
                if (selected) {
                  setState(() => _selectedDuration = duration);
                }
              },
            );
          }).toList(),
        ),

        const SizedBox(height: 20),

        // Options
        Text(
          'Options',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),

        // Include attachments
        if (widget.note.attachments.isNotEmpty)
          CheckboxListTile(
            title: const Text('Include attachments'),
            subtitle: Text(
              '${widget.note.attachments.length} attachment(s)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            value: _includeAttachments,
            onChanged: (value) {
              setState(() => _includeAttachments = value ?? true);
            },
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
          ),

        const SizedBox(height: 16),

        // Error display
        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Create link button
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _isCreatingLink ? null : _createSecureLink,
            icon: _isCreatingLink
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.link),
            label: Text(_isCreatingLink ? 'Creating...' : 'Create Link'),
          ),
        ),

        const SizedBox(height: 16),

        // Info box
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.security, color: theme.colorScheme.primary, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'End-to-end encrypted. You\'ll approve each access request.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildShareLinkSuccess(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Success icon
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check_circle, color: Colors.green, size: 48),
        ),
        const SizedBox(height: 16),
        Text(
          'Link Created!',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Expires in ${_selectedDuration.label}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),

        const SizedBox(height: 20),

        // Link display
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outline),
          ),
          child: Row(
            children: [
              Icon(Icons.link, color: theme.colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _shareResult!.shareUrl,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Action buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _copyLink,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: _shareLink,
                icon: const Icon(Icons.share, size: 18),
                label: const Text('Share'),
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // Info about approval
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                color: theme.colorScheme.secondary,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'You\'ll get a notification when someone requests access.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _createSecureLink() async {
    setState(() {
      _isCreatingLink = true;
      _error = null;
    });

    try {
      final result = await NoteShareService().createShareLink(
        note: widget.note,
        duration: _selectedDuration,
        allowModification: _allowModification,
        includeAttachments:
            _includeAttachments && widget.note.attachments.isNotEmpty,
      );

      if (mounted) {
        setState(() {
          _shareResult = result;
          _isCreatingLink = false;
        });
      }
    } catch (e) {
      if (mounted) {
        // Extract user-friendly error message
        String errorMessage = e.toString();
        if (errorMessage.contains('Exception:')) {
          errorMessage = errorMessage.replaceFirst('Exception:', '').trim();
        }
        if (errorMessage.contains('unauthorized') ||
            errorMessage.contains('permission')) {
          errorMessage =
              'Storage permission denied. Please try again or contact support.';
        }
        setState(() {
          _error = errorMessage;
          _isCreatingLink = false;
        });
      }
    }
  }

  void _copyLink() {
    if (_shareResult != null) {
      Clipboard.setData(ClipboardData(text: _shareResult!.shareUrl));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Link copied to clipboard')));
    }
  }

  Future<void> _shareLink() async {
    if (_shareResult != null) {
      await SharePlus.instance.share(
        ShareParams(
          text: _shareResult!.shareUrl,
          title: 'Shared Note: ${widget.note.title ?? "Note"}',
        ),
      );
    }
  }
}

/// Helper function to show the share note dialog
Future<void> showShareNoteDialog(BuildContext context, Note note) async {
  // Check if the note is locked
  if (note.locked && !note.unlocked) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Please unlock the note first to share it'),
        backgroundColor: Colors.orange,
      ),
    );
    return;
  }

  // Show the share type picker first
  final shareType = await showDialog<_ShareType>(
    context: context,
    builder: (context) => _ShareTypePickerDialog(note: note),
  );

  if (shareType == null || !context.mounted) return;

  switch (shareType) {
    case _ShareType.text:
      await _shareAsText(context, note);
      break;
    case _ShareType.markdown:
      await _shareAsMarkdown(context, note);
      break;
    case _ShareType.link:
      await showDialog<bool>(
        context: context,
        builder: (context) => _SecureLinkDialog(note: note),
      );
      break;
  }
}

/// Get attachment files as XFiles for sharing
Future<List<XFile>> _getAttachmentFiles(Note note) async {
  final List<XFile> files = [];

  // Early return if no attachments
  if (note.attachments.isEmpty) return files;

  final fs = await fileSystem();

  for (final attachment in note.attachments) {
    String? sourcePath;
    String? mimeType;
    String? fileName;

    switch (attachment.type) {
      case AttachmentType.image:
        sourcePath = attachment.image?.src;
        // Detect MIME type from file extension
        final ext = sourcePath?.split('.').lastOrNull?.toLowerCase();
        mimeType = switch (ext) {
          'png' => 'image/png',
          'gif' => 'image/gif',
          'webp' => 'image/webp',
          _ => 'image/jpeg',
        };
        fileName = 'image_${files.length}.${ext ?? 'jpg'}';
      case AttachmentType.sketch:
        sourcePath = attachment.sketch?.previewImage;
        mimeType = 'image/png';
        fileName = 'sketch_${files.length}.png';
      case AttachmentType.audio:
        sourcePath = attachment.recording?.src;
        // Detect audio MIME type from file extension
        final audioExt = sourcePath?.split('.').lastOrNull?.toLowerCase();
        mimeType = switch (audioExt) {
          'mp3' => 'audio/mpeg',
          'wav' => 'audio/wav',
          'aac' => 'audio/aac',
          'ogg' => 'audio/ogg',
          _ => 'audio/mp4', // m4a is audio/mp4
        };
        fileName =
            attachment.recording?.title ??
            'audio_${files.length}.${audioExt ?? 'm4a'}';
    }

    if (sourcePath == null) continue;

    try {
      // Read file bytes (handles decryption if encrypted)
      final bytes = await readEncryptedBytes(sourcePath);
      files.add(XFile.fromData(bytes, name: fileName, mimeType: mimeType));
    } catch (e) {
      // Try raw read as fallback
      try {
        final bytes = await fs.readBytes(sourcePath);
        files.add(XFile.fromData(bytes, name: fileName, mimeType: mimeType));
      } catch (e2) {
        // Log the failure but continue with other attachments
        AppLogger.error(
          'Failed to read attachment for sharing: $sourcePath',
          e2,
        );
      }
    }
  }

  return files;
}

Future<void> _shareAsText(BuildContext context, Note note) async {
  final text = note.plainText ?? '';
  final title = note.title ?? 'Note';

  // Get attachment files
  final attachmentFiles = await _getAttachmentFiles(note);

  await SharePlus.instance.share(
    ShareParams(
      text: '$title\n\n$text',
      title: title,
      files: attachmentFiles.isNotEmpty ? attachmentFiles : null,
    ),
  );
}

Future<void> _shareAsMarkdown(BuildContext context, Note note) async {
  final markdown = ExportDataService().noteToMarkdown(
    note,
    includeMetadata: false,
  );
  final title = note.title ?? 'Note';

  // Get attachment files
  final attachmentFiles = await _getAttachmentFiles(note);

  await SharePlus.instance.share(
    ShareParams(
      text: markdown,
      title: '$title.md',
      files: attachmentFiles.isNotEmpty ? attachmentFiles : null,
    ),
  );
}
