/// Account-shared metadata contains only a master-key-encrypted capability.
/// Provider refresh tokens and passwords are never part of this document.
class StorageConnection {
  const StorageConnection({
    required this.provider,
    required this.libraryId,
    required this.accountLabel,
    required this.encryptedCapability,
    required this.generation,
    required this.enabled,
    required this.state,
    this.updatedAt = 0,
    this.credentialVersion = 2,
    this.clientId = '',
    this.storageEpoch = '',
    this.clearOperationId = '',
  });

  final String provider;
  final String libraryId;
  final String accountLabel;
  final String encryptedCapability;
  final int generation;
  final bool enabled;
  final String state;
  final int updatedAt;
  final int credentialVersion;
  final String clientId;
  final String storageEpoch;
  final String clearOperationId;
  bool get hasEncryptedCredentials =>
      credentialVersion == 2 || credentialVersion == 3;
  bool get isReady => hasEncryptedCredentials && enabled && state == 'ready';

  // Reconnecting another provider account must not reuse the old change cursor
  // or acknowledgements, even when it uses the same encrypted library.
  String get replicaId =>
      '$provider:$generation${storageEpoch.isEmpty ? '' : ':$storageEpoch'}';

  factory StorageConnection.fromJson(Map<String, dynamic> data) {
    final provider = data['provider'];
    final library = data['libraryId'];
    final generation = data['generation'];
    if (![
          'google_drive',
          'dropbox',
          'nextcloud',
          'webdav',
        ].contains(provider) ||
        data['connectionId'] != provider ||
        library is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(library) ||
        generation is! int ||
        generation < 1 ||
        data['updatedAt'] is! int ||
        (data['updatedAt'] as int) < 0 ||
        (data['updatedAt'] as int) > 9007199254740991 ||
        data['enabled'] is! bool ||
        data['accountLabel'] is! String ||
        data['encryptedCapability'] is! String ||
        (data['encryptedCapability'] as String).length > 16384 ||
        ![
          'ready',
          'reconnect_required',
          'disconnecting',
          'disconnected',
          'clearing',
        ].contains(data['state'])) {
      throw const FormatException('Invalid storage connection');
    }
    final epoch = data['storageEpoch'] ?? '';
    final clear = data['clearOperationId'] ?? '';
    if (epoch is! String ||
        (epoch.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(epoch)) ||
        (data['credentialVersion'] == 3 && epoch.isEmpty) ||
        clear is! String ||
        (clear.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(clear))) {
      throw const FormatException('Invalid storage reset context');
    }
    return StorageConnection(
      provider: provider as String,
      libraryId: library,
      accountLabel: data['accountLabel'] as String,
      encryptedCapability: data['encryptedCapability'] as String,
      generation: generation,
      enabled: data['enabled'] as bool,
      state:
          const [2, 3].contains(data['credentialVersion']) ||
              data['state'] == 'disconnected'
          ? data['state'] as String
          : 'reconnect_required',
      credentialVersion: const [2, 3].contains(data['credentialVersion'])
          ? data['credentialVersion'] as int
          : 1,
      storageEpoch: epoch,
      clearOperationId: clear,
      clientId: data['clientId'] is String ? data['clientId'] as String : '',
      updatedAt: data['updatedAt'] as int,
    );
  }

  StorageConnection withAccountLabel(String label) => StorageConnection(
    provider: provider,
    libraryId: libraryId,
    accountLabel: label,
    encryptedCapability: encryptedCapability,
    generation: generation,
    enabled: enabled,
    state: state,
    updatedAt: updatedAt,
    credentialVersion: credentialVersion,
    clientId: clientId,
    storageEpoch: storageEpoch,
    clearOperationId: clearOperationId,
  );

  bool hasSameSession(StorageConnection other) =>
      credentialVersion == other.credentialVersion &&
      clientId == other.clientId &&
      storageEpoch == other.storageEpoch &&
      clearOperationId == other.clearOperationId &&
      provider == other.provider &&
      libraryId == other.libraryId &&
      generation == other.generation &&
      enabled == other.enabled &&
      state == other.state &&
      encryptedCapability == other.encryptedCapability;
}
