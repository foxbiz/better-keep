typedef RemoteLocalIdAvailability = Future<bool> Function(int candidate);

/// Resolves one stable local row ID for a remote document.
///
/// Existing identity mappings are authoritative. New reservations and source
/// device suggestions are accepted only when they do not collide with local
/// notes, sync tracks, or another active retry-ledger reservation.
Future<int> resolveRemoteLocalId({
  required int? trackedLocalId,
  required int? stableNoteLocalId,
  required int? reservedLocalId,
  required int? suggestedLocalId,
  required RemoteLocalIdAvailability isAvailable,
  required int Function() allocateCandidate,
}) async {
  if (trackedLocalId != null) return trackedLocalId;
  if (stableNoteLocalId != null) return stableNoteLocalId;

  if (reservedLocalId != null && await isAvailable(reservedLocalId)) {
    return reservedLocalId;
  }
  if (suggestedLocalId != null && await isAvailable(suggestedLocalId)) {
    return suggestedLocalId;
  }

  var candidate = allocateCandidate();
  while (!await isAvailable(candidate)) {
    candidate++;
  }
  return candidate;
}
