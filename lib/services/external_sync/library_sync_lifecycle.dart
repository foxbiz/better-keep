import 'package:flutter/foundation.dart';

import '../async_keyed_serializer.dart';
import 'library_sync_session.dart';
import 'sync_provider_adapter.dart';

/// Serializes account/key/database replacement while invalidating the old
/// generation immediately, including a session still being constructed.
class LibrarySyncLifecycle extends ChangeNotifier {
  final _transitions = AsyncKeyedSerializer<String>();
  final _retiring = <LibrarySyncSession>{};
  LibrarySyncSession? _session;
  Object? _identity;
  Future<void>? _transition;
  int _generation = 0;
  bool _disposed = false;
  SyncProviderFailureKind? failure;

  LibrarySyncSession? get session => _session;
  bool get initializing => _identity != null && _transition != null;

  Future<void> replace(
    Object? identity,
    Future<LibrarySyncSession> Function(bool Function() current)? create,
  ) {
    if (_disposed) return Future.value();
    if (_identity == identity &&
        (_transition != null ||
            _session != null ||
            (identity == null && _retiring.isEmpty))) {
      return _transition ?? Future.value();
    }
    final generation = ++_generation;
    _identity = identity;
    failure = null;
    final previous = _session;
    _session = null;
    if (previous != null) {
      previous.removeListener(_changed);
      previous.retire();
      _retiring.add(previous);
    }
    bool current() =>
        !_disposed && generation == _generation && identity != null;
    late final Future<void> transition;
    transition = _transitions
        .run('library', () async {
          try {
            for (final retired in _retiring.toList()) {
              await retired.close();
              _retiring.remove(retired);
            }
            if (!current()) return;
            final candidate = await create!(current);
            if (!current()) {
              candidate.retire();
              _retiring.add(candidate);
              await candidate.close();
              _retiring.remove(candidate);
              return;
            }
            _session = candidate;
            candidate.addListener(_changed);
          } catch (_) {
            if (generation == _generation && !_disposed) {
              failure = SyncProviderFailureKind.unavailable;
            }
            rethrow;
          }
        })
        .whenComplete(() {
          if (identical(_transition, transition)) {
            _transition = null;
            if (!_disposed) notifyListeners();
          }
        });
    _transition = transition;
    notifyListeners();
    return transition;
  }

  Future<void> stop() => replace(null, null);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Call and await [stop] before disposing an owner that removes local data.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _session?.removeListener(_changed);
    _session?.retire();
    _session = null;
    super.dispose();
  }
}
