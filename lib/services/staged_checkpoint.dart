/// Holds a candidate checkpoint in memory until an entire paginated pull has
/// completed. A failed page can therefore never advance durable sync state.
class StagedCheckpoint<T> {
  // ignore: prefer_initializing_formals
  StagedCheckpoint({required void Function(T value) commit}) : _commit = commit;

  final void Function(T value) _commit;
  T? _candidate;

  void stage(T value) {
    _candidate = value;
  }

  void commit() {
    final candidate = _candidate;
    if (candidate != null) {
      _commit(candidate);
    }
  }
}
