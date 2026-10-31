/// Provider-reported account capacity, not the size of Better Keep's files.
class StorageUsage {
  const StorageUsage({
    required this.freeBytes,
    required this.totalBytes,
    this._usedBytes,
  });
  final int freeBytes, totalBytes;
  final int? _usedBytes;
  // Preserve reported usage even when it exceeds the quota or shares a pool.
  int get usedBytes => _usedBytes ?? totalBytes - freeBytes;

  static int? bytes(Object? value) {
    final parsed = value is int
        ? value
        : value is String
        ? int.tryParse(value)
        : null;
    return parsed != null && parsed >= 0 && parsed <= 9007199254740991
        ? parsed
        : null;
  }

  static StorageUsage? fromUsed(Object? used, Object? total) {
    final u = bytes(used), t = bytes(total);
    if (u == null || t == null) return null;
    return StorageUsage(
      freeBytes: (t - u).clamp(0, t),
      totalBytes: t,
      usedBytes: u,
    );
  }
}

abstract interface class StorageUsageReader {
  Future<StorageUsage?> readStorageUsage();
}
