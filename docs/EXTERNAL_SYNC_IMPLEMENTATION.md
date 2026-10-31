# External sync implementation

## Accepted requirements

One generic core with Firebase, Google Drive, Nextcloud and Dropbox adapters;
iCloud deferred. One selected destination replicates the library both ways.
Multiple accounts can stay connected, but only one provider syncs at a time.
Keep Better Keep identity, device approval and encryption recovery. Manual external sync
is free. Lite and Pro add automatic external updates; Firebase uploads remain Pro.
Drive uses hidden appDataFolder. One account per provider initially. Connection
settings and access restore automatically on approved devices.

SQLite remains local. Remote storage uses immutable encrypted objects and JSON
commit records, published after their dependencies. Every note publication
includes its metadata. Stable note/label UUIDs and revision IDs propagate without
being restamped. Latest UTC modification time wins; exact ties prefer deletion,
then revision ID. No conflict copies. Retain tombstones/history for v1; absence
is not deletion. Include labels, reminders, custom ordering, locked notes and
source media (exclude derived sketch previews). No remote payload may depend on
another provider's file URL.

Storage credentials are encrypted on-device with the existing note-encryption
master key. Firebase stores ciphertext and coordinates refresh leases. Google
code exchange and refresh use an authenticated function that sees tokens only
while processing the request; tokens are never persisted or logged there. Other
provider exchanges and revocation remain client-side. New device approval
requires QR/security-code verification in both directions. See the current
security/configuration/transition sections below for the deployment boundary.

Dedicated settings page: compact cards, a single radio selection (including
Better Keep cloud and Sync off), and connect dialogs. Details, last successful
sync, manual sync and disconnect live in overflow menus. Additive initial reconciliation; disconnect retains notes and revokes
access where supported. Check account/library/key generation. Include the
selected destination in logout warnings, recovery, attachment retries and progress.
Scheduling: manual reconciliation for everyone; Lite/Pro add two-second save
debounce, launch/resume reconciliation and batched Firebase change hints.
There is no periodic provider polling. No server
file-transfer proxy or closed-app continuous-sync guarantee. Nextcloud requires
HTTPS and appropriate CORS for browser use. Keep manual external sync independent of subscription entitlements. No production changes, deployments or publishing without permission.

## Provider selection and browser return

`users/{uid}/sync_settings/firebase` now stores `provider` alongside the legacy
`enabled` flag and server timestamp. `enabled` is true only for `firebase`.
The shared confirmed selection gates both Firebase and external adapters. Changing
selection retires the old external session immediately; failed writes keep sync
stopped locally until retry. Credentials and per-provider cursors are retained.
Legacy settings without `provider` map to Firebase when enabled, or Sync off when
disabled. Previously connected external accounts remain available to select.
Rules validate the provider and flag together; load the updated rules in the
emulator (and deploy them before releasing these clients).

Native provider authentication returns to the app through the platform SDK or
an authentication session. Web uses a user-initiated popup. Browser tab closure
is best effort. Storage credentials never pass through the backend callback.

## Replication implementation and prior verification history

- `SyncVersion` shares logical edit identity between Firebase, the local journal
  and encrypted `SyncRevision` manifests. Timestamp ordering and ties are common.
  Keyed content fingerprints allow independently encrypted copies of one source
  revision to converge. The portable codec verifies that fingerprint and plaintext
  media hashes inside the encrypted payload before applying content.
- `SyncProviderAdapter`: opaque cursors, encrypted immutable objects and commits.
- `SyncReplicaStore`: account/library-scoped current revisions, independent
  acknowledgements, atomic inbox/cursor staging, persistent tombstones.
- `SyncReplicaEngine`: pull/apply/push with hash verification, dependencies before
  commit, captured-revision acknowledgements, session guards, isolated provider
  failures and invalid-cursor bootstrap. Content application and acknowledgements
  share the domain transaction. Retrieved immutable objects are hash-verified
  before caching or publication. Only the selected provider supplies an active adapter.
  Library/session composition and app account/key/foreground wiring are implemented.
- Schema v12 adds replica state and a SQLite-triggered local version journal.
  Imports, reminder actions, permanent deletes, locks and protected repairs are
  captured with their domain transaction. Local encryption/preview/path-only
  maintenance does not restamp notes. Remote adoption uses a nested transaction
  guard to preserve source versions. Firebase note and label adoption use the
  same journal, including live order snapshots.
- `SyncObjectCache` stores verified encrypted objects in the app filesystem and
  keeps library-scoped local fingerprints for media deduplication across edits.
- `SyncAttachmentStore` materializes portable media inside app storage, applies
  local at-rest encryption when enabled and verifies writes before indexing them.
  Its account/library/note/object cache verifies files before reuse, replaces
  missing, edited or corrupt files, and does not reuse plaintext when encryption
  has since been enabled. Unindexed partial/cancelled writes are removed; committed
  files remain available to existing references. Schema v12 includes its index.
- `PortableSyncCodec` serializes notes, label records, reminders, custom ordering
  and opaque PIN-protected media. It replaces file paths with encrypted object
  references and excludes generated sketch previews. Missing media blocks that
  note's publication; a source file is never silently omitted.
- `LibraryReplicaContent` prepares files outside SQLite, checks durable local
  versions during incoming commit, queues Firebase fan-out and preserves source
  revisions. A local edit during an incoming download remains pending and wins
  according to the common comparator. Inbox/outgoing processing is paginated.
- Tests using two isolated local libraries verify complete encrypted media transfer,
  labels/reminders/order, forwarding without restamping, delete/revive behavior,
  concurrent edits, persistent media deduplication and missing-media retries.
- Firebase notes now use payload-bound metadata. An older merge writer's changed
  payload invalidates stale metadata and gets a deterministic legacy identity;
  timezone-less legacy wire dates cannot establish UTC and use server commit stamps when available; ambiguous unstamped live records are deferred. Incoming notes and tombstones compare
  journal versions in their domain transaction. Outgoing note snapshots are
  captured atomically and the final Firestore replacement compares the latest
  remote version in a transaction. Pending local work is no longer an unconditional
  winner; publication retries retain the captured source version.
- Firebase note creation dates are sent in UTC. Tests verify that a full Firebase
  round trip produces the same external semantic fingerprint despite independent
  object encryption. They also cover stale deletes, revivals, newer remote edits
  over pending work, local edits during downloads and remote edits during commit.
- Firebase labels now share the version comparator, payload-bound metadata and
  transactional final writes. Incoming label content, source version and queue
  acknowledgement commit together, preserving timestamps and system-label flags.
  Local label rename/deletion authors note membership changes atomically, with
  independent note revisions. Receivers apply those note changes separately.
- Duplicate label names created on different devices retain their distinct sync
  identities while appearing as one folder, using a deterministic representative.
  Local rename/deletion updates all known same-name identities. Legacy name repair
  is disabled once the replica journal exists, so it cannot recreate deleted
  labels from stale note memberships or discard a remote identity by name.
- Live Firebase order snapshots now preserve the journal's source revision and
  exact UTC timestamp. Local edits advance past future received timestamps;
  snapshot/position/journal writes are atomic. Defaults are not new edits and
  cannot replace a prior tombstone. Journal bootstrap retains existing order IDs.
- Ordering uses the shared latest-version comparator instead of replaying pending
  moves into newly stamped winners. The final Firestore transaction compares
  source versions independently of the previous Firebase base. Manifests bind an
  ordered-ID hash, and chunk retries verify existing bytes rather than overwrite
  them. Legacy physical chunk names remain separate from normalized edit IDs.
  Legacy cloud migration retains source time and cannot overwrite a newer order.
- Missing order dependencies can be restored from a complete matching local
  snapshot, or superseded by an authentic newer local edit. Partial libraries do
  not synthesize replacement ordering. Source chunks and prior revisions are
  retained; old cleanup requests are retired locally to avoid racing another
  device's publication. There is no automatic remote history collection in v1.
- Order tests cover atomic rollback, future clocks, reversed delivery during
  drag, immutable retry, concurrent Firebase commits, stale bases, missing chunks,
  and default-context recreation after deletion. A synthetic Firebase round trip
  preserves an external order's source revision and keyed semantic fingerprint.
- Missing Firebase documents no longer synthesize deletion events. Note deletion
  and upload paths retain source files to avoid deleting files needed by another
  writer's revival. Reference-aware collection is not implemented; retained local
  and Firebase source storage can grow. Protected legacy sketches without a usable
  source block Firebase publication instead of being silently omitted.
- Isolated tests cover failure, restart, concurrent edit, rollback, tombstones,
  revision identity collisions, object corruption and account isolation.
- `SyncCipher` derives account/generation-bound, purpose-separated keys from the
  existing UMK and uses existing XChaCha20-Poly1305 primitives. Objects use
  ciphertext hashes; JSON commits encrypt note identifiers and revision metadata.
- `FileSyncAdapter` implements the shared immutable encrypted file protocol,
  including logical equality checks for commit retries with different nonces.
- `DropboxSyncTransport` implements App Folder operations, incremental cursors,
  conditional immutable creation and 8 MiB upload sessions for larger files.
- `NextcloudSyncTransport` implements HTTPS WebDAV, namespace-aware XML parsing,
  ETag-based discovery in pages of 100 commits, conditional creation, and strict
  directory/origin validation. HTTP transfers disable authenticated redirects.
  A pre-connection canary verifies that conditional PUT preserves existing bytes
  before the connection controller registers the grant.
- Provider tests use mocked HTTP only; no real provider account was accessed.
- `GoogleDriveSyncTransport` implements appDataFolder objects, capture-before-list
  bootstrap, incremental change cursors and resumable uploads. Drive duplicate
  names are handled by the optional `SyncFileCopies` capability; the common file
  protocol authenticates all copies and rejects conflicting revision contents.
- The old server vault/OAuth brokerage has been replaced by client-encrypted
  credentials and direct provider authorization. See the security section below;
  earlier OAuth test counts in this history apply to the superseded flow.
- `StorageConnectionController` owns consent, encrypted registration, Nextcloud
  probing, metadata updates, local account-label decryption and disconnect.
- The controller restores multiple connections independently and creates guarded
  `StorageProviderSession` adapters. Metadata/key/generation changes retire the
  old HTTP client and broker. A failed pause remains stopped locally until a
  newer confirmed setting arrives. Errors are sanitized, key mismatches block
  access, and incomplete provider-side revocation is returned for the UI to show.
- Public connection metadata timestamps advance monotonically, including updates
  within one server clock tick. This prevents delayed snapshots from undoing a
  completed connection mutation. Consent results remain usable while the metadata
  listener catches up, without accepting older connection generations.
- Optional native keychain/keystore caching is scoped to environment, account,
  device, library, provider and generation. Cached grants still require the current
  capability to decrypt. Cache operations serialize across replacing sessions;
  disposal clears credentials and prevents late writes from restoring them.
  Web persistence is disabled. Tests mock the secure-storage boundary; real OS
  keychain behavior and lifecycle integration remain acceptance work.
- Current-stage tests include backend credential races, synthetic OAuth exchange,
  Firestore-emulator consent/registration races, server-only rules, client
  capability isolation and in-flight credential disposal. Real grants and
  provider interoperability remain untested.
- `SyncScheduler` uses two-second save debounce and launch/resume reconciliation
  when automatic access is enabled; manual reconciliation remains free. It has
  independent provider backoff and sanitized
  progress. Saves during an upload request a follow-up pass. Replacement adapters
  with the same replica ID wait for retired work rather than coalescing into it.
- `LibrarySyncSession` composes the connection controller, scheduler, portable
  codec, replica engine and attachment store for one account/key/database. Retirement
  invalidates work synchronously and drains engine/filesystem tasks before cleanup.
  Large initial captures continue in bounded pages and remain pending rather than
  claiming complete success. Incoming winners clear replaced local capture failures.
  `ExternalSyncService` instantiates this owner from app startup, restored/fresh
  sign-in and approved-key availability. Note/label/order changes debounce outgoing
  work for Lite/Pro; foreground changes control change listeners and reconciliation. Logout drains external work before
  database/filesystem cleanup. External readiness does not depend on Firebase
  transport readiness or Pro, and review identities are excluded.
- `LibrarySyncLifecycle` invalidates old generations synchronously and serializes
  creation and draining. Late initialization after logout is closed without being
  attached; rapid identity changes skip superseded creation. Initialization failures
  stay recoverable and sanitized instead of making restored login fail.
- Committed replica callbacks carry their create/update/delete event and local row.
  `ReplicaModelNotifier` checks the durable version after model decryption, emits
  remote-origin events, requests reminder reconciliation/cancellation and schedules
  Firebase fan-out. Superseded callbacks cannot overwrite newer UI models. Order
  refresh reads durable state without restamping and defers visual changes while
  dragging; deletion removes stale in-memory snapshots.
- Session-stage verification uses in-memory databases, temporary files and fake
  providers: encrypted-source round trips, mutation races, cache recovery, paging,
  connection replacement, independent retries and retirement during downloads.
  Tests cover encryption at the file boundary; no live account or keychain was used.
- `SyncStatusStore` retains successful pass times locally, scoped to account,
  encryption library and connection generation. Schema v12 includes its table.
  Monotonic writes survive restart and clock reversal; failed or partial passes
  do not advance success. Paused connections retain their last successful time.
- Settings links to `StorageSyncPage` with one account-wide provider selection.
  Compact cards open connection dialogs; menus expose details, manual sync,
  reconnect and confirmed disconnect. Radio buttons appear after the menu icon.
  Native OAuth opens the browser after preparation; web uses a separate gesture
  to avoid popup blocking. The Nextcloud
  app-password dialog validates HTTPS, obscures credentials and retains them only
  for the connection operation. Key mismatches link to account/encryption recovery;
  expired grants offer reconnect. Incomplete provider revocation is shown explicitly.
  Widget tests cover these interactions and a narrow large-text layout using fake
  services. The compact settings copy is translated in all seven supported locales;
  unrelated existing generated-file edits were preserved.

- OAuth cancellation now atomically fences pending registration and discards
  unused session secrets without altering an existing provider connection.
  Cancellation authenticates the app-held verifier and capability, including after
  ticket expiry. If registration already completed, the app explicitly reports
  the connection and offers Disconnect. Failed cancellation retains the proof for
  retry and stops that provider locally. Controller/widget and demo-emulator tests
  cover completion and token-exchange races, expired/superseded tickets, proof
  rejection and preservation of an existing grant.

- Nextcloud browser authorization implements [Login Flow v2](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html)
  alongside manual app passwords. A separate Continue gesture opens the browser;
  polling is bounded to 20 minutes and stays within the selected HTTPS server and
  installation. Tokens and one-use credentials stay in memory; failed account
  lookup or connection setup can retry without consuming the grant again.
  Cancelling the dialog or ending the account session closes the HTTP client and
  ignores pending responses. Local cancellation does not revoke an app password
  already granted on Nextcloud; settings explain where to revoke access.
  Current-user OCS lookup separates the WebDAV user ID from the authentication
  login name. That ID is carried inside the encrypted vault and native secure
  cache; old/manual credentials retain the existing username fallback.
  Tests use fake HTTP and verify endpoint restrictions, expiry, cancellation,
  single-consumption retries, UI gestures, canonical paths and credential restore.

- Firebase library sync has an account-wide selection at
  `users/{uid}/sync_settings/firebase`, separate from authentication, device
  approval and Pro eligibility. A missing server document preserves existing
  enabled behavior; cache misses and optimistic enables do not authorize a new
  session. The settings switch pauses locally before writing, waits for server
  confirmation to resume, retains failed intent for retry, and rejects stale or
  old-account results. Notes, labels and ordering stop their listeners/timers and
  invalidate in-flight work on pause. Local edits remain queued and external
  providers remain independent. Rules restrict the preference to its owner,
  boolean selection and a server timestamp; free users may change it.

- Manual refresh now starts external destinations independently of the Firebase
  note/label attempt and skips Firebase when paused. External refresh waits for
  connection metadata, drains bounded capture batches, retains per-provider
  errors and rejects completion after account/connection replacement. Pending
  local edits update scheduler status immediately during the save debounce.
  The shared sync indicator observes enabled external providers as well as
  Firebase; active transfers remain visible during Firebase outages, and one
  provider's success cannot clear another's failure or pending work. Firebase
  note counts are hidden while external transfers are active. Empty cached
  connection snapshots cannot falsely establish that no providers are enabled.

- Firebase ordering participates in manual refresh after note/label reconciliation.
  Refresh verifies server manifests, joins bootstrap and in-flight uploads, and
  waits for pending ordering writes. Invalid/missing dependencies, deferred work
  and Pro-restricted uploads contribute to the shared indicator instead of being
  concealed by successful note sync. Duplicate refresh requests coalesce, and
  account changes/pause invalidate completion. The focused ordering/manual-sync
  suite passed 177 tests with clean static analysis.

- Firebase-only attachment URLs can now be read during external capture through
  the configured Storage SDK. The reader validates the bucket and account's note
  namespace, guards session replacement, removes account encryption, and retains
  inner PIN ciphertext. The portable revision contains encrypted object bytes,
  never Firebase URLs. Remote sketch hashes are checked before capture to reject
  a legacy mutable path overwritten since its note metadata was saved. No mutable
  URL cache or local note rewrite is introduced. Fake-storage tests verify transfer
  to a second provider after Firebase sources are removed, corrupt/missing sources,
  account isolation and cancellation.

- Locked sketches containing deprecated device-key metadata now remain pending
  until the existing PIN-authenticated local migration replaces that source.
  The codec never decrypts those locked metadata fields or exports them as if
  another device could read them; incoming portable payloads reject them too.
  Legacy PIN ciphertext can remain opaque, with its drawing defaults preserved
  in the portable payload. The media/migration/revision suite passed 49 tests.

- Scheduled account deletion removes top-level storage OAuth sessions before
  deleting user subcollections and retains the deletion marker if cleanup fails.
  Review-account reset includes these sessions in its inspection and cleanup.
  Credential transactions and OAuth preparation/completion read the user document
  in the same transaction and reject missing accounts or scheduled deletion, so
  an already-authenticated request cannot recreate credentials during cleanup.
  Deleted OAuth slots cannot be recreated by a delayed provider callback.
  Verification passed 23 backend unit tests and 13 demo Firestore emulator tests,
  including cleanup isolation, retry, callback and registration races. Provider
  HTTP was mocked; no account deletion was run against live data.

- Sign-out now checks durable current-revision acknowledgements for every enabled
  external destination, including notes, labels, ordering and tombstones. Firebase
  checks include missing queue records, pending/failed/in-flight uploads, label
  deletions and dirty ordering. Paused Firebase does not warn about its queue when
  all selected external destinations have acknowledged the library; with no
  selected external destination, local-only changes still trigger a warning.
  Missing metadata/database access or a changing account/connection gives an
  explicit unverified result rather than assuming sync succeeded. Conditional
  warning text avoids claiming that changes saved to another provider are lost.
  Account changes while confirmation is open cancel that sign-out action.
  Firebase order tombstones are checked against account-scoped acknowledgements.
  Eight in-memory database tests cover the check.

- Firebase order manifest/repository support now accepts source-version-preserving
  tombstones with zero chunks and note IDs. Deletes win timestamp ties; newer live
  orders can revive the context. Firestore rules accept only canonical empty
  tombstones from paid owners. `FirebaseOrderTombstones` reuses the existing
  acknowledgement table in a separate account-scoped Firebase namespace, preserves
  the captured deletion across races and ignores older acknowledgements.
  The ordering service receives and publishes tombstones without restamping,
  clears ordering rows/operations atomically, and defers visible deletion while
  dragging. Conflict recovery uses the shared comparator; newer live ordering
  can replace a pending delete. Pauses and restricted uploads leave deletion
  pending, while manual refresh and progress include it. Blocked/dragged contexts
  do not prevent other deletions from uploading. The sign-out check recognizes
  durable Firebase acknowledgements. Verification: 198 focused Flutter tests and
  17 replica integration tests passed with clean static analysis, including a
  fake Drive-to-Firebase-to-Dropbox deletion through a fresh local library. Ten
  isolated rules-emulator tests passed for the unchanged tombstone wire rules.

- Missing local media can now be recovered from the session's Firebase file
  mapping during external capture. Only a validated missing app path qualifies;
  local read/decryption errors do not fall back. Recovery requires one unambiguous
  mapping with a SHA-256 hash, validates the account/bucket, removes outer account
  encryption and checks the recovered bytes before publication. PIN bytes stay
  opaque. Neither the note, mapping nor missing local file is rewritten. Tests
  cover changed remote bytes, conflicting/unverified mappings, account isolation
  and restoration on a second device after the fake Firebase source is removed.

- Protected device-key sketches now report a distinct unlock-required status in
  provider settings, with instructions to unlock the notes on their original
  device and retry. The message clears after migration and recapture. Historical
  list-only PIN sketches retain their separate background color and page pattern
  through model loading, serialization and external sync; current file-backed
  locked sketches still omit drawing details from attachment metadata. The
  combined media recovery, migration, scheduler and settings suite passed 84
  isolated tests with clean focused static analysis.

- All 26 storage-sync messages now have Portuguese, Indonesian, Japanese, Korean,
  Turkish and Simplified Chinese translations. Existing locale content is retained.
  The settings and Nextcloud dialog pass narrow 320-pixel layout checks at 1.8x
  text scale in all six translated locales; the settings suite passed 15 tests.

- Clean-login recovery now has an integrated test using the real controller,
  credential broker, Dropbox transport, scheduler, encrypted protocol and SQLite
  application against an in-memory Dropbox HTTP boundary. It destroys the first
  device's database/files/cache and restores a fresh library using only saved
  connection metadata and the recovered UMK. Notes, genuine PIN-encrypted content
  and media, labels, reminders, ordering and tombstones restore without restamping
  or repeating consent. A paused provider stays paused; an incorrect master key
  cannot activate the connection or request a credential. This is local integration
  evidence, not a real provider or native secure-storage acceptance test.

- The full regression run exposed a startup wait on external provider initialization.
  Restored-session and offline-continuation startup now start external sync in the
  background, independently of Firebase recovery. Retired note/label callbacks
  check their generation before accessing account state. Transactional publication
  also rejects cached/unacknowledged snapshots before acknowledging outgoing work.
  The focused startup/recovery/sync suite passed 117 tests with clean analysis.

- Retry/cache identity review: changed legacy Firebase payloads invalidate prior
  source metadata even when their timestamp is unchanged; deterministic content
  identities break equal-time ties. Local object reuse is keyed by content hash,
  not path/time, and remote immutable-name conflicts verify the existing bytes.
  These contracts are covered by the version, file-adapter and Drive duplicate
  tests. Changes made only to a legacy mutable media URL, without any corresponding
  note metadata publication, cannot be discovered as a new note edit; published
  source hashes detect an overwritten source instead of silently substituting it.

- A reproduced capture-status race is fixed: when an old media read fails after
  a newer incoming revision has committed, the failure is discarded rather than
  leaving the restored note permanently blocked. The failure path checks the
  current journal revision before recording its status. The regression test failed
  before the fix and passes afterward.

## Credential security and device pairing (2026-10-24)

Provider credentials and account details are encrypted on the client using a
separate HKDF purpose derived from the existing note-encryption master key.
XChaCha20-Poly1305 uses a fresh random nonce for every envelope. Context binds the
user, encryption library, provider, connection generation and OAuth client ID.
Note/media formats and the replica engine are unchanged. The backend stores
ciphertext and capability hashes; it cannot open the new envelopes.

Pairing uses **one scan with a temporary QR secret**. Manual code comparison
retains the two-device confirmation fallback.

1. The new device creates its request from its own public key, device ID,
   account/environment identity, protocol version and a random 256-bit request ID.
   It also generates an independent random 256-bit pairing secret. The public
   `toJson()` request goes to Firebase; the versioned QR wrapper containing the
   secret lives only in native secure storage or browser memory and on screen.
   Do not log, upload or share that QR. It contains no master key or credentials.
2. The trusted device scans the QR, checks its public identity against the pending
   request, and immediately approves the exact verified key. It transactionally
   rechecks the request and wraps the master key in the existing request-bound
   encrypted format. It never uses a replacement public key fetched afterward.
3. The trusted device adds a version-1 HMAC-SHA-256 proof over the domain-separated
   handoff fingerprint. That fingerprint binds the complete request, sender public
   key, ciphertext and nonce. Firebase receives the proof, never the secret.
   HMAC is the standard shared-secret message-authentication construction described
   in [RFC 2104](https://www.rfc-editor.org/rfc/rfc2104).
4. The new device verifies the proof using its locally stored secret and accepts
   only that exact handoff. It needs no return scan or confirmation button. It
   stores the accepted fingerprint before stripping the secret from local storage,
   so a crash between these writes can resume the same handoff safely. A different
   handoff cannot replace an already accepted fingerprint.

The public request and wrapped-key formats remain version 2; the private QR
wrapper and optional `pairing_proof` have their own strict version 1. Server
request parsing rejects private wrappers and extra fields. Unknown proof versions
and malformed tags fail closed. The security code is still the first 128 bits of
SHA-256 over the public, canonical, domain-separated request payload. Comparing
that code does not expose or authenticate the QR secret, so code-based approval
still displays a return QR/code that the new device must verify explicitly.
Older public-only requests also use this fallback. Generate a **new verification
code** to enable one-scan pairing for a request created before this update.

Requests and their QR secrets expire after ten minutes. Regeneration creates a
new request and secret; cancellation/logout clears local pairing state. Key or
account changes invalidate pending operations. Accepted native handoffs restore
after expiry only if their exact fingerprint matches; they no longer need the
consumed secret. Browser reload discards the secret along with all encryption
keys. First-device setup, recovery and existing approved devices remain usable.
All approving devices must be updated before claiming backend-substitution
protection; older clients retain their earlier unverified behavior. Protection
also assumes the pairing QR is scanned privately and the client is trustworthy.

Firebase coordinates revisions and 60-second refresh leases. The shared Google
exchange function handles code exchange and refresh transiently; other grants
refresh directly with providers. Clients revoke directly with providers. Generations, capability checks, lease fences,
account/device transaction checks and lifecycle guards reject stale writes.
Identical ciphertext retries recover lost registration/refresh responses. A
process crash or prolonged outage during a rotating refresh can still require
fresh consent; no claim is made that provider refresh and Firestore form one
atomic transaction. Revocation cannot erase keys or grants already copied by a
previously authorized device.

Browser encryption keys and decrypted credentials are memory-only. Reloading
requires approval or recovery, then restores the encrypted shared provider grant
without another provider sign-in. Migration removes only old E2EE key preferences;
notes/files are retained. A non-secret per-account history marker prevents a
previously initialized browser account from silently creating a replacement key
when no device record is found. Native secure storage remains enabled.

## Provider configuration

Merge the PUBLIC client IDs from [the root environment example](../.env.example)
into the existing Flutter build configuration; use
`--dart-define-from-file=.env`. Never copy an OAuth web-client secret or a vault
key into a Flutter build. Real `.env` and Secret Manager values have not been
changed by this implementation.

| Provider/platform | Authorization and setup |
| --- | --- |
| Google all platforms | Hosted authorization-code flow with PKCE, using one Web application OAuth client. `prepareStorageTokenExchange` returns public configuration; `exchangeStorageOAuthToken` exchanges and refreshes via fixed Google endpoints. Tokens are returned to the approved client and encrypted with its master key before storage. Native callbacks return through the existing app/loopback relay; web uses the same-origin popup. |
| Dropbox native | App Folder app; set `DROPBOX_CLIENT_ID` (app key). Register `https://betterkeep.app/oauth/storage/callback` and the same path at the development origin configured by `EMULATOR_WEB_ORIGIN`. The static hosted page relays the code/state to the app scheme on mobile/macOS or a random loopback port on Windows/Linux. Only HTTPS callbacks are registered with Dropbox; no client secret or server token exchange is used. |
| Dropbox web | Register `https://YOUR_ORIGIN/oauth/storage/callback` on the same origin as the app. Hosting serves `app/storage-auth.html` at that public route; no token exchange runs on the server. The same-origin callback posts only to the requesting popup opener and attempts to close. Firebase clean URLs are supported. Request offline PKCE access; store the grant only in a user-encrypted envelope. Decrypted credentials stay in memory and restore after approval/recovery. |
| Nextcloud | Direct Login Flow v2 or an app password; encrypt locally after the conditional-write probe. HTTPS and browser CORS remain required. Manual revocation uses the account's security settings. |

The hosted storage route stays `/oauth/storage/callback`; `/oauth/callback`
belongs to account sign-in. Ship the updated static callback page before using
the updated native flow. No new environment key is required: emulator-mode
native builds use `EMULATOR_WEB_ORIGIN`, and live builds use the production origin.
`DROPBOX_DESKTOP_REDIRECT_URI` is no longer used. Keep previously registered
native/desktop redirects while older app versions still need them.

The relay accepts only the fixed app scheme or a bounded loopback port encoded
in a random OAuth state, never an arbitrary return URL. The receiving client
checks the exact return endpoint and state and exchanges the code directly with
Dropbox using the original HTTPS redirect and PKCE verifier. The static page
removes the query from browser history, loads no external resources, and uses
no-referrer/no-store headers. Hosting and upstream proxy access logs should omit
callback query strings; they contain a short-lived authorization code and state.
Physical-device authorization and desktop browser loopback navigation still
need live acceptance testing after the hosted page and app are updated.

Keep Google clients in the **same Google Cloud project** as the existing app-data
integration and keep the same Dropbox app to retain access to existing remote
files. Enable Drive API and configure consent-screen test users as appropriate.
Requested scopes are Drive app-data and account email; Dropbox account-info,
metadata read, and file-content read/write within App Folder.

Storage consent never signs in to Firebase. Mobile authorization uses the
platform authentication session, which returns to the
app. Desktop browsers may prevent tab closing; a return message remains.
The hosted relay never exchanges codes or receives provider tokens.
Remote web origins require HTTPS. For local browser testing,
Dropbox also accepts `http://localhost`; register the exact callback, including
the port and base path (for `npm run dev web`,
`http://localhost:63630/oauth/storage/callback`). A different test port needs its own
registered redirect. The app does not substitute localhost for the configured
HTTPS development origin. Mobile callbacks never use localhost.

Once a provider has a reusable grant, device approval unlocks both notes and
provider credentials. A newly approved device needs no Google login and does not
need the original device online. Browser keys remain memory-only: reload still
requires Better Keep approval or recovery.

New Google grants use `oauth_exchange`. Set `GOOGLE_DRIVE_CLIENT_ID` in Functions
configuration and `GOOGLE_DRIVE_CLIENT_SECRET` in Secret Manager (or emulator
`.secret.local`). Register `https://betterkeep.app/oauth/storage/callback` and
that same path on your configured development origin on the **same Web client**.
Keep Firebase's `/__/auth/handler` redirects. For emulator testing, Functions and
the app must use the same `EMULATOR_WEB_ORIGIN`. Never put the secret in Flutter.
Deploying functions, changing production secrets, and live cleanup require approval.

The generic `oauthTokenExchange` transport accepts only server-owned provider
configuration. The storage callable additionally enforces authenticated approved
devices, rate limits, and the current capability/generation/revision/refresh lease
before and after refresh. Add future providers through a server-owned registration;
do not accept arbitrary endpoints or secrets from callers. Dropbox keeps direct PKCE.
Alongside counters and encrypted envelopes, the server stores a contextual HMAC
refresh-token fingerprint and pending exchange metadata. Successful initial code
exchange issues a ten-minute signed receipt that the updated client submits during
registration. The fingerprint binds the UID, provider, connection, OAuth client
and generation; refresh verifies it before contacting the provider. Rotation commits
the new fingerprint atomically with the encrypted credential update. The receipt
is not stored in the client-encrypted credentials.

This uses the existing Google client secret with separate signing purposes, not a
vault encryption key. `registerEncryptedStorageConnection` also needs that secret
binding. Deploy the updated client and backend together: existing unbound exchange
grants require fresh consent once, while direct grants and built-in sync are
unchanged. Rotating the client secret invalidates fingerprints and also requires
fresh consent. No plaintext refresh token is persisted. Token responses and
raw provider errors must never be logged. The backend can observe tokens while
exchanging them; this is an explicit privacy tradeoff, not zero-access credentials.
Notes, media, and master keys remain end-to-end encrypted.

Legacy `google_device` connections require fresh consent once, on any approved
device, to obtain a reusable grant for the same Drive account. Existing Apple and
desktop grants keep their direct refresh path. No remote notes/files are migrated.
Google can still revoke or expire a grant; real re-consent cannot be eliminated.
An in-flight rotating refresh whose response is lost can require re-consent, so a
future rotating provider needs explicit recovery design before enabling it here.

The shared-grant regression runs in Dart and Chrome with the real client policy:
it restores an encrypted iOS grant on a fresh browser, refreshes with the issuing
client ID, publishes only encrypted rotation, restores it on another device, and
restores again after browser-memory loss. A synthetic unauthenticated Google token
request confirmed CORS response headers for the development origin; it did not
prove a real provider refresh. Real-device authorization/sync acceptance remains
required. Firebase skip logs include the selected provider.

Provider references: [Google installed applications](https://developers.google.com/identity/protocols/oauth2/native-app),
[Google web token model](https://developers.google.com/identity/oauth2/web/guides/use-token-model),
[Google native user credentials](https://developers.google.com/identity/sign-in/ios/reference/Classes/GIDGoogleUser),
[Dropbox OAuth/PKCE](https://docs.dropboxapi.com/dropbox-api/docs/oauth).

## Transition and explicit deployment/cleanup boundary

The existing `STORAGE_VAULT_KEYS` records are **not decrypted or migrated**.
Legacy connections display reconnect-required; the reconnect dialog asks users
to revoke the old grant in their provider settings before giving fresh consent.
Disconnecting an old record discards its vault ciphertext without opening it.
Local notes, remote files, provider cursors and selection UI remain intact.

The following are prepared in source only; deployment and live cleanup require
separate permission:

1. Release updated clients with mutual device verification, and update every
   approving device before claiming protection against backend key substitution.
   Warn browser users that reload now needs approval/recovery.
2. Deploy the ciphertext callables: `registerEncryptedStorageConnection`,
   `getEncryptedStorageCredentials`, `acquireStorageRefreshLease`,
   `finishStorageRefresh`, `releaseStorageRefreshLease`,
   `setStorageConnectionEnabled`, `beginStorageDisconnect`, and
   `disconnectStorageConnection`, plus the reviewed rules/client assets.
3. Deploy the retained tombstone handlers over the old endpoints:
   `prepareStorageOAuth`, `completeStorageOAuth`, `cancelStorageOAuth`,
   `connectNextcloudStorage`, and `getStorageAccess` reject old clients;
   `storageOAuthStart` and `storageOAuthCallback` return HTTP 410 without echoing
   callback codes. Removing exports alone would leave previously deployed
   functions reachable. Confirm these handlers are live before removing old
   hosting rewrites or deleting endpoints. The public `/oauth/storage/callback`
   route now serves the browser callback asset; the direct legacy Function URL
   remains retired and performs no token exchange.
4. Have users revoke old grants, then reconnect. Confirm new private records use
   version 2 ciphertext and public account labels are empty (labels decrypt only
   in the client). Do not inspect credentials or request private keys for this.
5. After explicit cleanup approval, remove obsolete legacy vault records and
   `storageOAuthSessions`, and retire their TTL policy if no longer needed.
   Delete old **storage-only** Secret Manager versions/bindings for
   `STORAGE_VAULT_KEYS`, Google/Dropbox confidential clients, and obsolete storage
   OAuth configuration only after checking no other deployed service uses them.
   Do not delete Firebase-login OAuth secrets. Keep backups subject to the user's
   retention policy; deleting a current secret does not undo earlier exposure.

No live database query, deployment, secret deletion, grant revocation, or account
configuration was performed by the agent. Earlier screenshots of the old Google
connection flow are not evidence for the new direct-authorization flow.

## Validation and remaining real-device acceptance

Focused automated coverage includes one-scan secret isolation/authentication,
manual two-direction QR/code matching, substituted
recipient/sender keys and ciphertext, account/environment binding, expiry,
replay/downgrade rejection, regeneration/cancellation during key-cache writes,
purpose/context isolation, browser migration,
PKCE callback validation, consent cancellation, direct token HTTP, refresh leases,
rotation retries, generation races, legacy transition, and synthetic replica restore.
Backend tests run with synthetic ciphertext and a separate demo Firestore emulator;
no test depends on a real provider grant or user files.

User-reported device verification on 2026-10-24: sync is working on the primary
iPhone and new browser, with the test note visible in both supplied screenshots.
The user also reported duplicate labels only in the tab bar. The display fix now
reloads the model's deduplicated label list after sync events, including in the
label dialog; it does not merge or delete stored replicas. Its 33 focused widget,
dialog and filtering tests and targeted static analysis passed. Confirmation of
the corrected tabs on the rebuilt devices is still pending. The sync report does
not by itself verify token expiry/refresh, browser reload, deletions or media.

Direct Android/web authorization verification (2026-10-25–26):

- HTTPS browser retest on 2026-10-26 exposed a FlutterFire emulator-routing
  issue after reload: the SDK skips explicit Auth emulator setup when its
  session hint matches, but restores that hint automatically only on localhost.
  Fresh emulator app initialization now clears only that app's routing hint
  before explicit setup. The browser regression and five backend/identity tests
  passed, with focused analysis clean. Real HTTPS emulator sign-in then reached
  device verification, and the user approved the fresh browser. It restored the
  selected Android Drive identity. Direct Drive consent returned a reconnect
  error; browser provider authorization and media download remain unverified.

- Real Samsung Android device: Google consent completed, connected account and
  quota displayed, one QA text note with a sketch reported a successful manual
  Drive sync. A cold restart preserved the note and provider selection; a second
  manual sync succeeded without another Google prompt. Firebase remained signed
  into the same emulator QA account. This proves the Android upload/restart path,
  not yet a second-device media download or conflict test.
- 80 focused Flutter tests passed (one browser-only case skipped), including
  account binding, local token renewal, concurrent broker access, cancellation,
  connection-generation races and preserving existing encrypted reusable grants.
  41 browser regressions passed in isolated Chrome. One additional browser
  token-cache regression passed with a synthetic public client ID; it checks
  explicit-consent retry and logout cleanup.
- Real approved browser session restored the selected Android-created Drive
  connection on 2026-10-26. Manual sync correctly required local Drive consent.
  The first direct browser authorization attempt returned the generic connection
  error. The user's Google error screenshot confirmed `400 origin_mismatch`:
  the development origin must be registered under Authorized JavaScript origins
  on the web client matching `GOOGLE_DRIVE_WEB_CLIENT_ID`. This is an origin
  configuration issue, not a hosted callback mismatch. Real browser authorization
  and the note/sketch download remain unverified until that configuration is
  corrected and consent completes. Device approval alone is not evidence of
  provider authorization success.
- Android debug and web debug builds passed; web Wasm compilation dry run passed.
  Focused analysis passed. The latest iOS simulator build was blocked by stale
  Swift package artifact paths pointing to the checkout's previous location;
  macOS was not reached in that chained build. Windows/Linux runtime checks
  remain pending. Earlier build results below predate this authorization update.

Local verification completed for this change:

- Shared account-grant update: 75 focused checks passed, plus 12 Chrome checks
  covering grant restore/rotation, credential tampering and browser storage.
  The provider settings suite passed 21 checks after adding the initial-setup
  limitation message. Environment-example policy checks, static analysis and
  the updated web debug build also passed. These use synthetic provider tokens;
  they do not establish real Google/Dropbox authorization success.
- Latest full Flutter suite: 1,488 passed after guarding sync diagnostics when
  Firebase is not configured. The shared-grant suite also passed all 3 tests in
  Chrome, including overlapping refresh requests with Firebase's lease-busy
  error, encrypted token rotation and restore after reload. The 7 focused backend
  coordinator/security checks and static analysis passed. These checks use
  synthetic grants; remaining device checks are listed below.
- After the one-scan change, all 63 focused protocol,
  approval-service, pairing-widget and offline-startup checks passed, including
  cancellation during acceptance-fingerprint and key-cache writes.
- Full Functions suite: 191 passed; TypeScript and script type checking passed.
- Isolated ciphertext endpoint and Firestore-rules checks: 10 passed.
- Browser storage migration/session test passed in Chrome. Camera-denied and
  camera-free verification widget tests passed.
- The web debug build and Wasm compilation dry run also passed after the one-scan
  change; native-device pairing still needs the user's acceptance check.
- Android debug and iOS simulator builds passed again after the shared-grant
  update. The Android build reported future Kotlin plugin compatibility warnings;
  iOS reported existing Swift Package Manager support warnings for two plugins.
  Earlier macOS debug and web debug builds passed; the web Wasm dry run
  passed. These builds were not installed, launched, signed for distribution or
  deployed. The merged Android manifest keeps camera hardware optional and includes
  the storage callback scheme. Windows/Linux builds and real-device authorization
  still require platform checks.
- Final project static analysis and whitespace checks passed.

Before release, the user will run these on their devices and report results:

- Pair with one QR scan and no return dialog; test the full-code fallback in both
  directions and deny camera permission;
  expire/regenerate/cancel requests; retry after logout and restart.
- Authorize Google, Dropbox and Nextcloud on the intended platforms; confirm
  return-to-app behavior, declined Drive permission handling and unchanged Firebase
  login. Legacy access-token-only Google connections require one account-level
  setup on a supported platform; existing reusable grants must not request consent
  again on each approved device.
- Restore encrypted credentials on a second approved device, including an iOS
  Google Drive grant in a browser without another Google sign-in; refresh
  simultaneously, rotate tokens, switch providers, disconnect/reconnect, and test
  provider revocation failures and network loss.
- Verify note edits, deletions, labels, order, reminders, locked notes and source
  media converge across two devices. Confirm local and remote files survive the
  security transition.
- Reload the browser and verify approval/recovery is required and restores the
  existing reusable provider grants without another provider sign-in. Legacy Android/web
  device-local grants need one new connection to create a shared grant. Check real provider
  CORS, popup behavior and quota errors. Do not use production notes for acceptance.

These checks are not replaced by local unit tests or successful native builds.
This design cannot undo earlier key exposure, revoke already copied secrets, or
protect a compromised unlocked device or malicious client code.


## Review hardening (2026-10-24)

Provider responses have streaming and aggregate-copy bounds (512 KiB commits,
256 MiB encrypted media, 8 MiB metadata), and commits allow at most 1,024 blob
references. Corruption pauses automatic retries without advancing the failed page;
manual retry remains available after repair. Drive partial uploads resume from the
acknowledged offset with bounded stalls, and Nextcloud cursors bind to the library.
Canonical fingerprints normalize numbers across runtimes and retain a legacy
numeric-spelling validation path. Legacy wall-clock dates are never assigned a
fictional timezone; ambiguous unstamped live documents receive a lazy, transactional
server commit stamp through `stampLegacySyncDocument`, then the read is retried.
This does not rewrite note content or require users to migrate their library.

Interrupted disconnects can be retried. The OTP-verified reset removes credentials
encrypted with the discarded master key; external files remain untouched. Approval
checks the approver's current device record in the same transaction, permits a
one-minute future-clock tolerance, and preserves cancellation during recipient key
persistence. Manual receipt screens close on acceptance/change/expiry. Receipt
acknowledgements are UI signals, never an authentication source.

On session close, after all sync producers drain, at most 256 unreachable ciphertext
objects are removed. The reference graph includes entity revisions, inbox revisions
and every provider's last acknowledgement. Materialized attachment files and Firebase
tracks retain the existing conservative policy: deleting them requires tracking open
editors/drafts and recovery references, not just current database rows. That source
retention work and remote history collection remain future work.


## Storage-full feedback, safe clearing, and upgrade compatibility

Disconnected external cards say **Not connected · Free**. Connected cards omit
the price label and show provider-reported used/total capacity underneath their
status/account, refreshed while settings are open after sync or connection changes.
Quota lookup failures are informational only and cannot mark sync failed or force
reconnection. Unknown/unlimited totals remain unavailable rather than becoming zero.
Capacity comes directly from [Drive about.storageQuota](https://developers.google.com/workspace/drive/api/reference/rest/v3/about),
[Dropbox users/get_space_usage](https://github.com/dropbox/dropbox-api-spec/blob/main/users.stone),
and [Nextcloud root WebDAV quota properties](https://docs.nextcloud.com/server/latest/developer_manual/client_apis/WebDAV/basic.html).
Drive uses total usage across services; Dropbox team capacity respects enforced
member limits. No extra OAuth scopes or backend storage records are introduced.
Provider quota failures display a persistent storage-full warning with instructions
to free space and tap **Sync now**. Automatic retries pause for that connection;
local notes and pending changes remain intact. A successful manual retry resumes
normal scheduling. This is provider-capacity feedback, distinct from the existing
local-device storage-pressure warning.

**Clear synced data** is in each connected external provider's overflow menu.
It sends a six-digit code to the verified Better Keep account email. The private
challenge stores a hash, expires after ten minutes, permits five attempts, and has
a one-minute resend cooldown. It is bound to the account, provider, connection
generation, encryption library and current storage epoch. New callables are
`requestStorageClearOtp`, `beginStorageClear`, and `finishStorageClear`; the first
uses the existing email configuration/secret. Deploy these before releasing this
client, after explicit deployment approval.

After OTP verification, the backend disables the connection and clears its active
selection in the same transaction. The clearing device drains its local sync,
then deletes only the current library's provider objects. Credentials stay encrypted
and deletion runs directly on the client. Other accounts' libraries and local notes
are not deleted. Existing provider refresh work must finish before clearing starts;
only the clearing device may refresh credentials during cleanup. Interrupted cleanup
remains paused and can be resumed with a fresh code. This operation permanently
removes remote-only notes/media from the active library; export or download them first.
Provider retention/trash policies can delay reclaimed space.

Completion rotates a storage epoch and leaves sync off. The next explicit selection
uses a namespace derived from the user's encryption key, provider, and epoch, plus
new provider-scoped acknowledgements/cursors. It uploads retained local notes into
that fresh space. A raw server-supplied folder path is never trusted. This separates
new uploads from stale writes to the retired namespace. An already in-flight request
on another device cannot be recalled and may leave files in the retired namespace;
this is not a guarantee of immediate zero bytes across every outstanding provider
request. Whole-library cleanup is separate from deferred automatic history/media GC.

There is **no user migration for existing Firebase sync**: note/label paths,
encryption and payload formats remain readable by existing clients. Added metadata
is optional; old clients can keep reading and writing Firebase records. External
connections, credentials, local replica tables, acknowledgements and cursors are
separate bookkeeping; additive local tables do not move, delete or re-encrypt notes.
Backend deployment does not enable external sync in an old Firebase-only app.
Switching the account to an external provider therefore requires updated clients
on devices expected to use that provider.

Existing external connections retain their version-2 namespace and replica identity
until users explicitly clear them. Clearing uses connection protocol version 3 so
older prerelease external clients fail closed instead of writing into a cleared
library. This opt-in reset is not an upgrade migration. Provider file protocol and
note encryption stay unchanged. Do not remove compatibility readers or legacy
Firebase stamping endpoints during this release.

Release acceptance must include an old released Firebase client and a new client
against an isolated copy of the updated backend: text/media edits, labels, deletion,
offline return and subscription checks. Also test full provider quota, wrong/expired
OTP, interrupted clearing, two active devices during clearing, local-note preservation,
and re-enabling into the fresh namespace. Automated tests do not establish real
provider quota, SMTP delivery, live deletion or absence of all release bugs.


## Generic WebDAV

WebDAV is a separate provider (`webdav`) using the same DAV transport as Nextcloud.
Nextcloud retains its original account-root mapping and file format. Generic setup
accepts the exact HTTPS DAV collection URL, username and app password; it does not
append Nextcloud routes or use Nextcloud Login Flow v2. No new OAuth registration,
client secret, or environment variable is needed.

The client probes conditional create, readback, file ETags, listing and deletion
with a random canary before publishing encrypted credentials. Servers that ignore
`If-None-Match: *`, omit ETags, or redirect authenticated requests are unsupported.
Only `BetterKeep/<account-library-namespace>` is used for sync and OTP-authorized
cleanup. Credentials use the existing master-key encryption and approved-device
sharing. Quota is optional: unavailable DAV quota properties display unavailable
capacity instead of zero space. Existing Firebase/Nextcloud data needs no migration.

Browser sync requires a trusted HTTPS server to permit the app origin through CORS:
`GET`, `PUT`, `PROPFIND`, `MKCOL`, `DELETE`, with `Authorization`, `Content-Type`,
`Depth`, and `If-None-Match` request headers. CORS responses must cover errors too,
including expected `412` conditional-write responses. Basic authentication with an
app password is supported; Digest/NTLM authentication and self-signed TLS bypasses
are not. Use the canonical DAV URL so redirects are unnecessary. Password revocation
is manual in the storage server's account settings.

Local HTTP fixtures cover encrypted note/media/tombstone exchange between two
clients, encrypted credential registration/restoration, unsafe servers, account-scoped
cleanup, quota and UI setup. These checks do not certify any hosted WebDAV service;
real-server CORS and multi-device acceptance remain necessary before advertising a
specific server as supported. Backend/rules changes must be deployed separately with
permission before a live account can select WebDAV.

## Lite automatic updates and release gates (2026-10-24)

- Free: manual external sync. Lite: automatic external sync. Pro: automatic
  external sync, built-in cloud sync and unlimited locked notes. A generic paid
  check must not grant Lite built-in cloud access.
- After a successful provider publication, the replica acknowledgement transaction
  queues a durable notification token. `SyncChangeSignals` coalesces writes for
  15 seconds into `users/{uid}/storage_sync_signals/{provider}`. It contains only
  library/connection identifiers, device ID, a revision token and server time.
  Receivers reconcile provider cursors; the signal is not note content or an
  authoritative manifest. Applying remote data does not echo another signal.
- Rules require an unexpired Lite/Pro claim, matching enabled connection scope,
  a bounded payload and at least ten seconds between same-scope writes.
  Listeners close while backgrounded or without automatic entitlement. Failed
  hints retain an outbox entry and do not turn successful provider uploads into
  failed sync. Manual/resume reconciliation covers missed hints and older clients.
- Update Functions and rules before releasing Lite-aware clients. Existing Pro
  product IDs and built-in cloud data formats are unchanged. No note migration
  is required. Old clients do not understand Lite or publish change hints.
- Catalog setup is not release verification: sandbox purchases, restoration,
  expiration, upgrade/downgrade and real two-device notification delivery remain
  release gates. No production deployment or store activation is implied by
  local test results.

### Configured catalog

Apple uses the shared **Better Keep** subscription group: Pro at level 1 and
Lite at level 2. Lite product IDs are `lite_monthly` ($1.49 USD/month) and
`lite_yearly` ($10.49 USD/year). They remain drafts pending review.

Google Play product `better_keep_lite` has `lite-monthly` and `lite-yearly` base
plans, both drafts in 175 regions. US prices are $1.49/month and $10.49/year;
Google-calculated India prices are INR 140/month and INR 1,000/year. Regional
rounding means local prices are approximately, rather than exactly, half of Pro.

Android tier changes use an acknowledged, freshly queried and backend-verified
Play purchase as the replacement source. Both Lite → Pro and Pro → Lite use
`WITH_TIME_PRORATION`: immediate access changes with remaining value credited as
subscription time. The account page exposes the plan chooser. Other-store
subscriptions still use their owning store's management flow.

Verified Play replacements atomically retire their predecessor token. The marker
survives late restores/webhooks, so an old Pro record cannot override a completed
Lite downgrade or reactivate after the replacement expires. Pending replacements
do not retire current access. Conflicting ownership or successor tokens fail
closed. Deploy this backend before enabling replacement purchases in clients.

Razorpay catalog plans follow its existing Pro prices (which differ from stores):

| Plan name | Amount per cycle | Plan ID |
| --- | --- | --- |
| `better_keep_lite_monthly_inr_v1` | INR 115.00 | `plan_TroBvKd6d3cNbD` |
| `better_keep_lite_yearly_inr_v1` | INR 812.50 | `plan_TroD07bcxept6M` |
| `better_keep_lite_monthly_usd_v1` | USD 1.49 | `plan_TroDlkBkH9gA3y` |
| `better_keep_lite_yearly_usd_v1` | USD 9.99 | `plan_TroEJDYCGYGyWt` |

These are catalog plans, not customer subscriptions. No customer was charged.
