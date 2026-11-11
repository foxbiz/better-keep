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
  - Web: approved device keys and completed pairing proofs are encrypted in local IndexedDB using a browser-generated, non-extractable AES-GCM key. After reload, a matching signed-in account and approved identity can open the local library offline. Cloud transfers wait for online device verification and master-key unwrapping. A device learns of remote revocation when it reconnects. Offline reopening also requires a non-secret grant in Web Storage. Revocation retires that grant independently of the IndexedDB write. The master key and pending pairing secrets remain in memory. The wrapping key lives in the same browser profile. Scripts running on the app origin can use it, and anyone with a compromised browser profile may recover device material. When the identity cannot be saved, approval lasts for this session. If the browser cannot read its device history, first-device setup waits until storage is accessible to avoid replacing an existing encryption key. Sign-out retires the local library and clears browser trust. If the trust record cannot be erased or verified as revoked, sign-out retires its local library using the persisted sign-out journal. Cleanup verifies the new library generation before completing, including while offline. A surviving identity bound to the retired library cannot unlock the new library. If retirement cannot be verified, the app offers Retry. Clearing site data or revoking the device requires approval or recovery again. The original `WEB_STORAGE_KEY` is retained only for read-only legacy recovery, not new key persistence.

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
  approved_by_public_key: "base64...", // Used only with local verification proof
  approval_protocol: 2,
  approval_request: { /* account, environment, device, locally held key, ID, expiry */ },
  wrapped_umk_version: 2,
  pairing_proof: "base64...",      // QR handoff authentication; no pairing secret
  accepted_receipt: "fingerprint..." // Completion hint, not standalone authorization
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

The pending device generates a ten-minute request from its locally held public key, account/environment, device ID and random request ID. Its QR also contains a fresh one-time pairing secret. That secret never goes to Firebase in plaintext and is not a master key or provider credential.

The trusted device scans the QR, checks the pending request and wraps the master key for the exact verified public key. The recipient verifies the request-bound handoff using its local pairing secret before accepting it. A successful scan completes pairing without an extra approval button.

Without a camera, the new device offers **Use a code instead**. It displays eight random digits; the trusted device enters them once and taps **Approve**. Both devices must remain online during this exchange. No second confirmation is needed on the new device.

Both clients run SRP-6a using Pointy Castle 4.0.0, the fixed RFC 5054 3072-bit group and SHA-256. The canonical request binds the account, environment, device, public key and request ID. Firebase relays public SRP values and evidence in the pending device's `code_pairing` field; the code, verifier and private ephemeral values remain in memory. After mutual evidence verification, an HKDF-derived key bound to the entire exchange encrypts the QR handoff secret. The trusted device then uses the same verified approval operation as QR, and the new device still requires the existing keyed pairing proof before accepting its master key.

A code expires after five minutes, allows at most three attempts enforced on the new device, and is invalidated by cancellation, regeneration, logout or request/key changes. Each attempt consumes a fresh ephemeral before processing evidence. Reloading loses the code and attempt state; a fresh request must be generated locally. Concurrent responses cannot reuse an ephemeral. An untrusted mailbox can deny service but cannot reset the local attempt budget or authorize a device by setting a flag.

Legacy code-mode requests remain decodable but a receipt without the QR secret proof is never accepted automatically. Older public-QR requests require a return QR scan. Both devices need an updated app to use the short-code fallback; QR and recovery remain available. This protocol composition has regression coverage, not an independent cryptographic audit; Dart BigInt arithmetic is not claimed to be constant-time. Compromised clients, observed codes and local side-channel attackers are outside its protection.

Isolated transport regression (creates only synthetic records in a disposable demo project):

```sh
node tool/firebase_cli.mjs -- emulators:exec --only auth,firestore \
  --project demo-better-keep-pairing --config firebase.emulator-tests.json \
  'flutter test --no-pub --platform chrome test/emulator/device_pairing.dart'
```

Cancellation, expiry, regeneration and identity changes invalidate pending verification. An accepted receipt fingerprint is retained so an already accepted handoff can be reloaded after the original request expires.

Existing devices with a cached master key remain usable. If that cache is missing, an unverified legacy envelope supplied by another device is rejected; use verified approval or recovery. First-device and recovery self-wrapping remain supported. Older approving clients retain their original trust weakness, so update all approving devices before relying on substitution protection.

### 3. Opening/Syncing Notes

```
1. App checks E2EE status on startup
2. If device is approved:
   a. Load cached UMK from secure storage, OR
   b. Unwrap an accepted, verified handoff (or first-device/recovery self-wrap)
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

Use the device-verification UI to scan the new device or enter its eight-digit pairing code. `DeviceManager.approveDevice` requires a `VerifiedDeviceApproval`; a device ID alone is insufficient. Notifications open verification and do not grant access themselves.

### External-provider credentials

`SyncCipher` derives a separate credential purpose from the existing user master key. Authenticated envelopes bind user, provider, library, connection generation and OAuth client identity. Firebase stores these envelopes, not plaintext credentials. Approved devices decrypt compatible grants locally.

For providers requiring a confidential OAuth client, the reusable exchange function sees authorization codes and tokens transiently during exchange/refresh. It does not persist or log them and never receives the user master key. This is a credential trust boundary; it does not change note/media end-to-end encryption. The exchange validates the approved session, connection capability, generation/revision, refresh lease and configured client before and after exchange. For brokered grants, an HMAC binds the refresh token to the user, provider, connection, OAuth client and connection generation. The exchange checks this binding before refresh and updates it on token rotation.

Built-in note/media remote formats remain unchanged. External sync stores its encrypted manifests, revisions and media in a separate account/library namespace, with independent per-provider cursors and acknowledgements.

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


### Pairing failure recovery

Code approval hides method changes while the authenticated handoff is in progress. If
approval does not arrive within 60 seconds of the code exchange, the waiting UI exposes
retry. That UI timeout does not revoke an already shared secret: choosing a new code/QR
regenerates the request and invalidates the abandoned handoff. A delayed, correctly bound
approval may still finish before regeneration.

Request publication journals only locally generated candidates and the previous accepted
fingerprint in native secure storage (encrypted IndexedDB for approved browsers). After an uncertain write, a
server read selects only a matching local candidate; an unknown request is never adopted.
Explicit regeneration can abandon a conflicting journal. Account/session fences remain
in force, including during rollback and cancellation.

SRP host/client setup and response computation use Flutter `compute`, which runs off the
UI isolate on native platforms. Web executes the same code on its main event loop; test
optimized builds on lower-end browsers before release. A dedicated web worker is not
implemented. The eight-digit field remains visible for usability; codes are short-lived
secrets and should not be shared, photographed or pasted into support logs.

Release checks include `npm test device-pairing` and the isolated demo-project
`npm test firebase-emulator-pairing`. The latter exercises protocol/services with a
ciphertext fixture; it is not a substitute for physical-device camera/keyboard UX checks.
