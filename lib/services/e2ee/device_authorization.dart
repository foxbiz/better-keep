/// Only confirmed server snapshots may change device authorization or keys.
bool isAuthoritativeDeviceSnapshot({
  required bool isFromCache,
  required bool hasPendingWrites,
}) => !isFromCache && !hasPendingWrites;

enum DeviceAuthorization { approved, pending, revoked, deleted, unavailable }

enum LocalEncryptionState {
  ready,
  pending,
  revoked,
  needsRecovery,
  missing,
  corrupt,
  unavailable,
  stale,
}

class SecureStorageUnavailable implements Exception {
  const SecureStorageUnavailable(this.cause);
  final Object cause;
}

Future<LocalEncryptionState> readLocalEncryption({
  required Future<bool> Function() hasDeviceKeys,
  required Future<String?> Function() readDeviceStatus,
  required Future<bool> Function() loadKey,
  required bool Function() isCurrent,
}) async {
  try {
    if (!isCurrent()) return LocalEncryptionState.stale;
    final status = await readDeviceStatus();
    if (!isCurrent()) return LocalEncryptionState.stale;
    // Previously confirmed restrictions survive missing keys and read errors.
    switch (status) {
      case 'pending':
        return LocalEncryptionState.pending;
      case 'revoked':
        return LocalEncryptionState.revoked;
      case 'needs_recovery':
        return LocalEncryptionState.needsRecovery;
    }
    final hasKeys = await hasDeviceKeys();
    if (!isCurrent()) return LocalEncryptionState.stale;
    if (!hasKeys || status != 'approved') return LocalEncryptionState.missing;
    final loaded = await loadKey();
    if (!isCurrent()) return LocalEncryptionState.stale;
    return loaded ? LocalEncryptionState.ready : LocalEncryptionState.missing;
  } on SecureStorageUnavailable {
    return isCurrent()
        ? LocalEncryptionState.unavailable
        : LocalEncryptionState.stale;
  } on FormatException {
    return isCurrent()
        ? LocalEncryptionState.corrupt
        : LocalEncryptionState.stale;
  }
}
