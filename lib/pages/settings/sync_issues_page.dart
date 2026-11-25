import 'dart:async';

import 'package:better_keep/pages/home/note_pane.dart';
import 'package:better_keep/components/duo_safe_area.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../dialogs/unlock_note_dialog.dart';
import '../../models/app_progress.dart';
import '../../models/note.dart';
import '../../services/sync_presentation.dart';
import '../../services/external_sync/external_sync_service.dart';
import '../../services/external_sync/library_replica_content.dart';
import '../../services/external_sync/library_sync_session.dart';
import '../../utils/l10n_helper.dart';
import '../../utils/progress_localizations.dart';
import '../../utils/utils.dart';
import '../note_editor/note_editor.dart';

Future<void> showSyncIssuesPage(
  BuildContext context, {
  ExternalSyncService? service,
}) async {
  final activeService = service ?? ExternalSyncService.instance;
  final session = activeService.session;
  if (session == null || !session.isCurrent) return;
  final navigator = Navigator.of(context);
  final closing = NotePaneHost.closeNote(context);
  if (closing != null &&
      (!await closing || !session.isCurrent || !navigator.mounted)) {
    return;
  }
  await navigator.push<void>(
    MaterialPageRoute(
      builder: (_) => SyncIssuesPage(service: activeService, session: session),
    ),
  );
}

/// A local recovery view. Never changes note contents, unlocks without a PIN,
/// or shares an old library's notes with a replacement session.
class SyncIssuesPage extends StatefulWidget {
  const SyncIssuesPage({
    super.key,
    required this.service,
    required this.session,
  });
  final ExternalSyncService service;
  final LibrarySyncSession session;

  @override
  State<SyncIssuesPage> createState() => _SyncIssuesPageState();
}

class _SyncIssuesPageState extends State<SyncIssuesPage> {
  late Future<List<SyncNoteIssue>> _notes;
  Map<String, SyncCaptureFailure> _failures = {};
  bool _busy = false, _retrying = false, _closing = false;
  SyncProgress? _feedback;
  bool _openFailed = false, _wasActive = false;
  Timer? _noteReload;
  final _ownedRoutes = <Route<dynamic>>{};

  bool get _current =>
      widget.session.isCurrent &&
      identical(widget.service.session, widget.session);

  @override
  void initState() {
    super.initState();
    _load();
    _wasActive = widget.service.progress.isActive;
    Note.on('changed', _noteChanged);
    widget.session.addListener(_changed);
    widget.service.addListener(_changed);
  }

  void _load() {
    _failures = Map.of(widget.session.content.captureFailures);
    _notes = widget.session.content.affectedNotes();
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) {
      if (_closing) return;
      _closing = true;
      final route = ModalRoute.of(context);
      final navigator = Navigator.of(context);
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!navigator.mounted) return;
        for (final owned in _ownedRoutes.toList().reversed) {
          if (owned.isActive) navigator.removeRoute(owned);
        }
        if (route?.isActive == true) navigator.removeRoute(route!);
      });
    } else {
      final active = widget.service.progress.isActive;
      final finished = _wasActive && !active;
      final failuresChanged = !mapEquals(
        _failures,
        widget.session.content.captureFailures,
      );
      if ((active && !_wasActive) || failuresChanged) {
        setState(() {
          _feedback = null;
          _openFailed = false;
        });
      }
      _wasActive = active;
      if (finished || failuresChanged) {
        _reload();
      }
    }
  }

  void _reload() {
    if (!mounted || !_current) return;
    _noteReload?.cancel();
    // Duplicate terminal notifications and coalesced edits preserve Retry
    // feedback. A new attempt or changed failures supersede it.
    setState(_load);
  }

  void _noteChanged(NoteEvent event) {
    if (!_current || !_failures.containsKey('note:${event.payload.syncId}')) {
      return;
    }
    // Clear only feedback that predates this edit. A later open failure must
    // survive the delayed reload (for example, an edit emitted during unlock).
    if (_openFailed) setState(() => _openFailed = false);
    // Coalesce a batch of edits/remote updates; transfer progress does not query.
    _noteReload?.cancel();
    _noteReload = Timer(const Duration(milliseconds: 50), _reload);
  }

  @override
  void dispose() {
    _noteReload?.cancel();
    Note.off('changed', _noteChanged);
    widget.session.removeListener(_changed);
    widget.service.removeListener(_changed);
    super.dispose();
  }

  Future<void> _retry() async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _retrying = true;
      _feedback = null;
      _openFailed = false;
    });
    try {
      final outcome = await widget.service.refreshWithOutcome();
      if (mounted && _current) {
        setState(() {
          _feedback = outcome == null
              ? null
              : syncRefreshProgress(
                  outcome,
                  noteIssuePhase: widget.service.progress.hasNoteIssues
                      ? widget.service.progress.phase
                      : SyncPhase.notesNeedAttention,
                );
          _load();
        });
      }
    } catch (_) {
      if (mounted && _current) {
        setState(() => _feedback = const SyncProgress(SyncPhase.failed));
      }
    } finally {
      if (mounted && _current) {
        setState(() {
          _busy = false;
          _retrying = false;
        });
      }
    }
  }

  Future<void> _open(SyncNoteIssue issue) async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _feedback = null;
      _openFailed = false;
    });
    try {
      final note = await widget.session.content.openAffectedNote(issue.syncId);
      if (!mounted || !_current || note == null) return;
      if (note.locked && !note.unlocked) {
        final unlocked = await showDialog<bool>(
          context: context,
          builder: (context) {
            if (ModalRoute.of(context) case final route?) {
              _ownedRoutes.add(route);
            }
            return UnlockNoteDialog(note: note);
          },
        );
        if (!mounted || !_current || unlocked != true) return;
        note.validateReadableContent();
      }
      await showPage(
        context,
        Builder(
          builder: (context) {
            if (ModalRoute.of(context) case final route?) {
              _ownedRoutes.add(route);
            }
            return NoteEditor(note: note);
          },
        ),
        allowFullScreen: true,
      );
    } catch (_) {
      if (mounted && _current) {
        setState(() => _openFailed = true);
      }
    } finally {
      _ownedRoutes.removeWhere((route) => !route.isActive);
      if (mounted && _current) {
        setState(() {
          _busy = false;
          _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.syncIssuesTitle)),
      body: DuoSafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                Expanded(
                  child: FutureBuilder<List<SyncNoteIssue>>(
                    future: _notes,
                    builder: (context, snapshot) {
                      final notes = snapshot.data ?? [];
                      final loading =
                          snapshot.connectionState != ConnectionState.done;
                      final message = snapshot.hasError
                          ? l10n.externalSyncFailure('localStorage')
                          : notes.isEmpty
                          ? l10n.syncIssuesEmpty
                          : null;
                      return ListView.builder(
                        itemCount:
                            1 + (loading || message != null ? 1 : notes.length),
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(l10n.syncIssuesHint),
                                  if (_openFailed) ...[
                                    const SizedBox(height: 12),
                                    Text(l10n.syncNoteOpenFailed),
                                  ],
                                  if (_feedback case final feedback?
                                      when !feedback.isEmpty) ...[
                                    const SizedBox(height: 12),
                                    Text(feedback.localized(l10n)),
                                  ],
                                ],
                              ),
                            );
                          }
                          if (loading || message != null) {
                            return Padding(
                              padding: const EdgeInsets.all(24),
                              child: Center(
                                child: loading
                                    ? const CircularProgressIndicator()
                                    : Text(message!),
                              ),
                            );
                          }
                          final issue = notes[index - 1];
                          final date = DateTime.tryParse(issue.updatedAt ?? '')
                              ?.toLocal();
                          final title = issue.locked
                              ? l10n.noteLocked
                              : issue.title.trim().isEmpty
                              ? l10n.untitledNote
                              : issue.title.trim();
                          return ListTile(
                            leading: Icon(
                              issue.locked
                                  ? Icons.lock_outline
                                  : Icons.description_outlined,
                            ),
                            title: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                if (issue.reason ==
                                    SyncCaptureFailure.unlockRequired)
                                  l10n.unlockNote
                                else
                                  l10n.syncIssueUploadFailed,
                                if (date != null)
                                  MaterialLocalizations.of(context)
                                      .formatMediumDate(date),
                              ].join(' · '),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _busy ? null : () => _open(issue),
                          );
                        },
                      );
                    },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _retry,
                      icon: _retrying
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(_retrying ? l10n.loading : l10n.syncRetryNow),
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
