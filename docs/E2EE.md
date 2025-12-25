# End-to-End Encryption (E2EE) Documentation

Better Keep implements end-to-end encryption to ensure that only you (and your authorized devices) can read your notes. The server (Firebase) never has access to your plaintext notes or encryption keys.

## Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              E2EE Architecture                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   Device A                    Firebase                    Device B          │
│   ┌──────────┐               ┌──────────┐               ┌──────────┐        │
│   │ KeyPair  │               │ Firestore│               │ KeyPair  │        │
│   │ (X25519) │               │          │               │ (X25519) │        │
│   └────┬─────┘               │ ┌──────┐ │               └────┬─────┘        │
│        │                     │ │Device│ │                    │              │
│        │  Public Key ───────►│ │ Docs │◄─── Public Key       │              │
│        │                     │ └──────┘ │                    │              │
│        │                     │          │                    │              │
│   ┌────┴─────┐               │ ┌──────┐ │               ┌────┴─────┐        │
│   │   UMK    │               │ │Notes │ │               │   UMK    │        │
│   │(unwrapped│               │ │(enc) │ │               │(unwrapped│        │
│   └────┬─────┘               │ └──────┘ │               └────┬─────┘        │
│        │                     │          │                    │              │
│        │ Wrapped UMK ───────►│ ┌──────┐ │◄─── Wrapped UMK    │              │
│        │                     │ │Wrapped││                    │              │
│        │                     │ │ UMKs ││                    │              │
│        │                     │ └──────┘ │                    │              │
│        │                     └──────────┘                    │              │
│        │                          ▲                          │              │
│        │                          │                          │              │
│   Encrypt/Decrypt             Encrypted                 Encrypt/Decrypt     │
│   Notes Locally               Notes Only               Notes Locally        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Key Model

### User Master Key (UMK)

- **What**: A random 32-byte symmetric key unique to each user
- **Purpose**: Encrypts all note content
- **Storage**: Never stored in plaintext on the server
- **Generation**: Created on the first device during E2EE setup

### Device Keypairs

Each device has its own X25519 keypair:

- **Private Key**: Stored only on the device (platform secure storage)

  - iOS/macOS: Keychain
  - Android: EncryptedSharedPreferences / Keystore
  - Windows: Windows Credential Store
  - Linux: libsecret
  - Web: IndexedDB with encryption

- **Public Key**: Stored on Firestore for other devices to use

### Wrapped UMK

- The UMK is "wrapped" (encrypted) for each authorized device
- Uses ECDH (X25519) to derive a shared secret, then XChaCha20-Poly1305 for encryption
- Each device's wrapped UMK is unique and only decryptable by that device

## Cryptographic Primitives

| Purpose                   | Algorithm          | Notes                                       |
| ------------------------- | ------------------ | ------------------------------------------- |
| Note Encryption           | XChaCha20-Poly1305 | Authenticated encryption with 192-bit nonce |
| Attachment Encryption     | XChaCha20-Poly1305 | Same algorithm, nonce prepended to file     |
| Key Exchange              | X25519 (ECDH)      | Derives shared secrets between devices      |
| Key Derivation (Recovery) | Argon2id           | Memory-hard KDF for passphrase-based keys   |
| Random Generation         | Cryptographic PRNG | Platform-native secure random               |

## What Gets Encrypted

| Content Type      | Encrypted | Notes                                       |
| ----------------- | --------- | ------------------------------------------- |
| Note title        | ✅ Yes    | Encrypted with note content                 |
| Note content      | ✅ Yes    | Rich text JSON is encrypted                 |
| Images            | ✅ Yes    | Encrypted before upload to Firebase Storage |
| Audio recordings  | ✅ Yes    | Encrypted before upload                     |
| Sketches          | ✅ Yes    | Preview images encrypted                    |
| Labels            | ❌ No     | Used for filtering/search                   |
| Colors            | ❌ No     | Used for display/sorting                    |
| Timestamps        | ❌ No     | Used for sync ordering                      |
| Pin/Archive flags | ❌ No     | Used for filtering                          |

### Attachment Encryption Details

Attachments (images, audio, sketches) are encrypted using the same UMK as notes:

- **Format**: `[nonce (24 bytes)][ciphertext][MAC (16 bytes)]`
- **Nonce**: Fresh 192-bit random nonce per file
- **Overhead**: 40 bytes added per file (24 nonce + 16 MAC)
- **Performance**: ~5-30ms for a 500KB file (negligible vs network transfer)

Files are encrypted before upload and decrypted after download. The encrypted files are stored in Firebase Storage with no content-type metadata that would reveal the file type.

**Backward Compatibility**: When downloading files, the system checks if the file appears encrypted (using magic byte detection). Unencrypted files from before E2EE was enabled are used as-is.

## Firestore Data Model

### Device Documents

Path: `users/{uid}/devices/{deviceId}`

```javascript
{
  name: "iPhone 15 Pro",
  platform: "ios",
  public_key: "base64...",          // Device's X25519 public key
  wrapped_umk: "base64...",         // UMK encrypted for this device
  wrapped_umk_nonce: "base64...",   // Nonce for wrapped UMK
  status: "approved",               // "pending" | "approved" | "revoked"
  created_at: "2024-01-01T...",
  approved_at: "2024-01-01T...",
  approved_by_public_key: "base64..." // Public key of approving device (for ECDH)
}
```

### Note Documents (E2EE enabled)

Path: `users/{uid}/notes/{noteId}`

```javascript
{
  local_id: 123,
  e2ee_enabled: true,
  e2ee_ciphertext: "base64...",     // Encrypted title + content
  e2ee_nonce: "base64...",          // Nonce for decryption
  e2ee_version: 1,                  // Version for future compatibility

  // Non-sensitive metadata (not encrypted)
  color: "0xFF000000",
  pinned: 0,
  archived: 0,
  trashed: 0,
  updated_at: "2024-01-01T...",
  attachments: [...]
}
```

### Recovery Key (Optional)

Path: `users/{uid}/e2ee/recovery_key`

```javascript
{
  encrypted_umk: "base64...",       // UMK encrypted with passphrase-derived key
  nonce: "base64...",               // Nonce for decryption
  salt: "base64...",                // Salt for Argon2id
  hint: "My hint",                  // Optional passphrase hint
  created_at: "2024-01-01T..."
}
```

## Flows

### 1. First Device Setup

```
1. User logs in on first device
2. App detects no E2EE setup (no devices in Firestore)
3. App generates:
   - Device X25519 keypair
   - User Master Key (32 random bytes)
4. App wraps UMK:
   - Derives shared secret from device keypair (self-encryption)
   - Encrypts UMK with XChaCha20-Poly1305
5. App stores:
   - Private key → Local secure storage
   - Public key + Wrapped UMK → Firestore device doc (status: approved)
6. E2EE is now ready
```

### 2. Adding a New Device

```
New Device:
1. Generate device keypair
2. Store private key locally
3. Upload public key to Firestore (status: pending)
4. Listen for approval

Existing Device:
1. Sees pending device in UI
2. User approves new device
3. Existing device:
   a. Gets new device's public key
   b. Derives shared secret (ECDH: own private + their public)
   c. Encrypts UMK with shared secret
   d. Uploads wrapped UMK to new device's doc (status: approved)

New Device:
1. Receives approval notification
2. Gets approving device's public key
3. Derives same shared secret (ECDH: own private + their public)
4. Decrypts UMK
5. Caches UMK locally
6. E2EE is now ready
```

### 3. Opening/Syncing Notes

```
1. App checks E2EE status on startup
2. If device is approved:
   a. Load cached UMK from secure storage, OR
   b. Fetch wrapped UMK from Firestore and unwrap
3. When downloading notes:
   a. Check if note has e2ee_ciphertext
   b. If yes, decrypt with UMK
   c. Display plaintext to user
4. When uploading notes:
   a. Encrypt title + content with UMK
   b. Generate fresh nonce
   c. Upload ciphertext + nonce
```

### 4. Revoking a Device

```
1. User selects device to revoke
2. App updates device doc: status = "revoked", removes wrapped_umk
3. Revoked device:
   - Detects revocation on next sync
   - Clears local keys and cached UMK
   - Cannot decrypt notes anymore
```

### 5. Recovery Flow

```
Setup Recovery (optional but recommended):
1. User enters recovery passphrase
2. App derives key using Argon2id(passphrase, random_salt)
3. App encrypts UMK with derived key
4. App stores encrypted_umk + salt in Firestore

Recovering Access:
1. User logs in on new device (no other devices available)
2. User enters recovery passphrase
3. App fetches encrypted_umk + salt from Firestore
4. App derives key using Argon2id(passphrase, salt)
5. App decrypts UMK
6. App registers new device with recovered UMK
7. E2EE is restored
```

## Security Properties

### What E2EE Protects Against

✅ **Server-side breaches**: Firebase admins/attackers cannot read note content
✅ **Network interception**: Data in transit is encrypted twice (TLS + E2EE)
✅ **Unauthorized device access**: Only approved devices can decrypt notes

### What E2EE Does NOT Protect Against

❌ **Compromised device**: If malware has access to your device, it can read decrypted notes
❌ **Weak recovery passphrase**: A guessable passphrase weakens recovery security
❌ **Browser extensions (web)**: Malicious extensions could read memory
❌ **Lost access**: If all devices are lost and no recovery key exists, notes are unrecoverable

## Usage in Code

### Initializing E2EE

```dart
// In your app initialization (after user login)
await E2EEService.instance.initialize();

// Check E2EE status
switch (E2EEService.instance.status.value) {
  case E2EEStatus.notSetUp:
    // Prompt user to set up E2EE
    break;
  case E2EEStatus.pendingApproval:
    // Show "waiting for approval" UI
    break;
  case E2EEStatus.ready:
    // E2EE is active, notes will be encrypted
    break;
  // ...
}
```

### Setting Up E2EE (First Device)

```dart
if (await E2EEService.instance.deviceManager.isFirstDevice()) {
  await E2EEService.instance.setupE2EE();

  // Strongly recommend setting up recovery
  await E2EEService.instance.recoveryKeyService.createRecoveryKey(
    'my-strong-passphrase',
    hint: 'favorite poem first line',
  );
}
```

### Approving a New Device

```dart
// On existing device
E2EEService.instance.deviceManager.pendingApprovals.addListener(() {
  final pending = E2EEService.instance.deviceManager.pendingApprovals.value;
  for (final request in pending) {
    // Show approval UI
    showApprovalDialog(request);
  }
});

// User approves
await E2EEService.instance.deviceManager.approveDevice(deviceId);
```

### Manual Encryption/Decryption

```dart
// Usually handled automatically by NoteSyncService, but if needed:
final e2ee = E2EEService.instance.noteEncryption;

// Encrypt
final encrypted = await e2ee.encryptNote(
  title: 'My Secret Note',
  content: '{"ops":[{"insert":"Hello world\\n"}]}',
);

// Decrypt
final decrypted = await e2ee.decryptNote(encrypted);
```

## File Structure

```
lib/services/e2ee/
├── e2ee_service.dart        # Main service (entry point)
├── crypto_primitives.dart   # Low-level crypto operations
├── device_manager.dart      # Device registration and UMK distribution
├── note_encryption.dart     # Note encrypt/decrypt
├── recovery_key.dart        # Recovery passphrase system
└── secure_storage.dart      # Platform-specific secure key storage
```

## Limitations

1. **Labels**: Labels are synced but not encrypted (they're used for filtering/search).

2. **Search**: Server-side search is not possible with E2EE. All search must be client-side.

3. **Metadata**: Some metadata (colors, pins, timestamps) is not encrypted to enable sorting/filtering.

## Future Improvements

- [ ] Searchable encryption for server-side filtering
- [ ] Key rotation support
- [ ] Audit log for device approvals
- [ ] Hardware key (FIDO2/WebAuthn) support for recovery
