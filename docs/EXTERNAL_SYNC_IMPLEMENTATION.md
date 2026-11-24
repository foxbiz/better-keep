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

## Interrupted uploads

External sync passes establish their own library account/key/database cloud-operation zone, so nested local writes do not inherit an expired startup/recovery guard; retirement still cancels the pass.

Before an outgoing pass, the client durably records an upload intent scoped to
account, encryption library and provider connection generation. Launch and
foreground resume finish runnable requested work even on Free. Once only blocked
sources remain, clear the intent while retaining pending/unlock/storage feedback;
later Free edits and repaired sources require another manual sync. Compare blocked
revision IDs with current journal versions so concurrent edits remain runnable. Switching
to another provider or Sync off stops scheduling the previous connection.
Selecting the same connection again resumes its retained intent. Disconnecting
and reauthorizing creates a new connection generation, so a Free user starts a
new upload with manual sync. Turning off automatic sync does not cancel work
already requested; after it finishes, later Free edits remain manual.
Transient failures keep the intent and retry with the existing provider backoff;
authorization, quota and corrupt-data failures still require user action.
Failures reading/writing local sync history or intent are reported as local
storage failures, with the existing retry backoff, rather than network outages.
The same classification covers SQLite exceptions escaping sync/restore and pending
queue checks. Local object-cache and attachment filesystem boundaries also report
storage failures, including browser file errors; cancellation and integrity errors
remain distinct. A typed attachment-source read failure blocks only that entity:
capture and upload continue for healthy notes, then report that some attachments
could not be uploaded while explaining that other notes can still sync.
Cache-write and database faults abort the pass and retain its durable intent.
Neither path acknowledges a failed mutation. The pill, details and manual-refresh
snackbar distinguish source-read failures from whole-pass device-storage failures.
Blocked-source feedback offers **View notes**, opening a local, revision-filtered
list of affected notes. The normal editor and PIN dialog handle opening/unlocking;
locked titles are masked in the query as well as the UI. Recovery reads reject
incomplete attachment/content decoding before opening an editable note, including
nested sketch parsing and unlocked editor content validation, preserving the original
row. Validation uses the editor compatibility normalizer without rewriting source
content; legacy inline/file sketches, audio formats, title headers and missing final
newlines remain supported. Locked content and legacy protected sketches stay opaque
until the existing PIN flow authenticates them; recovery validates the decrypted body
before opening the editor. Recovery validates the registered embed types and their
payloads: attachment identity/source strings, image/video source strings, and tables
through `NoteTableData.fromJson`, including populated cell Delta content and nested
tables. Missing attachment files remain valid references and show the existing
placeholder. Validation preserves optional legacy sizing and does not rewrite source
content. Embed cardinality is checked explicitly in release builds, and malformed
sketch or embed data raises a sanitized `FormatException`. Other readers retain
their defaults. The list refreshes after relevant note changes and finished sync
passes, without querying on each progress tick. Missing-attachment guidance suggests
syncing from the device where the attachment was added, without asking users to inspect files.
**Retry now** on that page runs a manual sync and reports its returned outcome
rather than a potentially stale global status. Late terminal notifications and list
reloads preserve that result; a new sync attempt or changed failure set clears it.
Provider details retain results across duplicate notifications but replace them when
the connection, error, blocked-note counts or pending state changes. An open failure
clears when affected notes change or a new sync starts. Details also disable duplicate
requests while waiting.
A note that cannot be opened gets
note-specific guidance without blaming storage. Opening the list does not grant
automatic sync or change upload intent. Session replacement closes the list and
its PIN/editor routes. Provider setup failures retain provider-level guidance,
and generic local-access errors do not assume the device is out of storage.
Cancelled passes retain upload intent without a network error, success stamp or
backoff retry; a subsequent manual/foreground request can resume them.
A foreground wake is kept separately from ordinary continuation callbacks until the
in-flight pass settles, including when it reports cancellation after resuming. Free
initial downloads receive up to three transient attempts per foreground visit; a new
visit renews unfinished restoration without enabling uploads or repeating completed
restores. Existing provider backoff, authorization and permanent-failure gates remain.
This resumes downloads when the app becomes active; it does not promise OS background
execution while iOS suspends the process.

Local-storage feedback intentionally takes precedence over generic failure.

Upload continuation requires a newly captured revision or a durable provider
publication. A pass with runnable work but no progress backs off from 5 to 300
seconds; the quiet "Sync will retry shortly" state and **Retry now** action explain
that wait without an active spinner. The waiting pill fades after three seconds;
the pending state remains available in provider details. A manual retry can bypass
it. Intent writes are skipped while the same intent is already known durable;
the SQLite transaction and retirement guards remain. Progress count pairs retain compact formatting unless rounding would show
equal counts before completion, in which case they use exact localized numbers.
Connection details close when their owning session is replaced.

Completion checks both the mutation journal and that connection's unacknowledged
revisions. The queued-revision check reads only entity identities and current local
revision IDs in bounded pages, avoiding payload decoding and per-entity database
round trips. It still checks every blocked revision to detect edits safely.
A download-only pass cannot claim completion while local uploads are pending. Settings label this timestamp "Last completed sync" and show pending
changes separately when no pass is running; it is not a last-download timestamp.
Open connection details observe current progress and completion. Bounded capture batches continue within the requested operation, without
a success flash or another pull-to-refresh. The v13 → v14 local migration adds a SQLite table that stores
only the intent; no backend, credential or remote-format changes are required.
An upload interrupted by an older build has no intent marker: one manual refresh
starts the resumable operation after upgrading.

Upload progress uses an animated upward transfer arrow, localized compact counts,
then remaining time and percentage above the progress bar. It omits the duplicate
total. Existing notes retain the floating pill; empty-library restore stays in the
content area. Reduced-motion settings stop the activity animation.

Validation for this change covers migration/history preservation, per-connection
intent isolation, failure/retry and Free-plan behavior, large-text layouts, and
both transfer animations. `integration_test/external_sync_platform_test.dart`
with `--dart-define=UPLOAD_RESUME_QA=true` exercises an encrypted 104-note/image
Dropbox-to-Drive switch, on-disk reopen, foreground resume and restore without
manual refresh. The transport boundary is synthetic; SQLite, files, encryption,
providers and scheduler are real.

`--dart-define=DOWNLOAD_RESUME_QA=true` runs a 104-note/media Dropbox download
interruption test. Add `--dart-define=DOWNLOAD_RESUME_OS_LIFECYCLE=true`, wait for
`DOWNLOAD RESUME READY FOR BACKGROUND`, background the QA app and reopen it. The test
uses real lifecycle callbacks to release a late cancellation, then checks complete
restoration without manual refresh, duplicate notes or Free-plan uploads. Without the
OS flag it injects the same lifecycle sequence for repeatable automation.

Local validation on 24 November 2026: the download-resume fixture passed on the iOS
26.3 simulator and Android emulator after opening OS Settings to background the QA
app and then reopening it. Both recovered all 104 notes and media without a refresh
or outgoing uploads. Cancellation was deliberately delivered after the foreground
event; this verifies the race, not unrestricted OS background downloading. The five
new scheduler cases failed before the fix; all 104 scheduler/refresh/content tests
and targeted analysis passed afterward. Live-provider/physical-iPhone confirmation
remains separate from these synthetic-provider lifecycle tests.

For an OS force-stop test, also pass a unique
`--dart-define=UPLOAD_RESUME_PROCESS=<run-id>`. The first launch reports
`UPLOAD PROCESS READY FOR FORCE STOP` with an unfinished queue. Stop the host
test runner without its automatic app-uninstall cleanup, terminate only the QA
app, then rerun with the same run ID. The new process must report
`UPLOAD PROCESS RESTART PASS`, complete the queue and restore every note/image
without `syncNow` or refresh. Use disposable simulators/emulators only.

Before shipping, smoke-test the release/TestFlight build against a real Drive
account while locking/unlocking and force-closing during upload; synthetic
transport tests do not qualify real-provider connectivity or OS background time.

## Bounded external publication

Non-batch providers publish through four note workers per pending page. Object
uploads shared by revisions use one future per object per page; retries start a
new page map and recheck remote durability. Revision checks remain before and
after object transfer, acknowledgements remain version-guarded, and failures
wait for in-flight workers before leaving the pass. Existence checks and writes
are awaited sequentially within each worker: this path has at most four provider
requests in flight, not eight. Dropbox's batch path is unchanged.

Verified local objects up to `SyncLimits.uploadBufferBytes` (1 MiB) can upload
beside a large transfer. Unknown or large objects are loaded and transferred
serially to avoid several full media buffers. Native and OPFS cached files use
size hints first, then the optional `FileSystemMetadata` capability to read cold
file sizes without loading content; account filesystem wrappers forward it.
IndexedDB has no cheap size lookup and uses bounded in-memory size hints. Cold
unknown IndexedDB objects conservatively retain the serialized path. No
ciphertext format changes in this buffering path.

Upload and download indicators report completed notes, not bytes. ETA retains
up to 32 completion samples, at most one per second, and needs eight completions
across ten seconds before estimating. It is approximate for mixed media sizes.
The last transfer remains visible through scheduler durability checks; a queued
pass clears it before its running notification, without a completion flash.
Backgrounding or disabling automatic sync between passes settles the status.
Engine progress emits transfers only; scheduler notifications own completion.
WebDAV/Nextcloud callers share one in-flight collection initialization; failures
clear it for a later retry. OPFS diagnostic file listings use metadata for size
instead of loading contents. Cache reads recheck existence after a read failure
and treat only confirmed absence as a miss. Programming errors propagate, and a
failed existence recheck preserves the original read failure and stack.

## Provider selection and browser return

`users/{uid}/sync_settings/firebase` now stores `provider` alongside the legacy
`enabled` flag and server timestamp. `enabled` is true only for `firebase`.
The confirmed selection gates outgoing Firebase sync and external adapters.
Firebase downloads (notes, labels, media and ordering) remain available on every
plan when Firebase or Sync off is selected. Sync off prevents outgoing changes;
pending local work is retained. External selections remain isolated from Firebase
downloads. Unknown/cached selections, account switches and failed selection writes
still fence transfers. This is client-only; existing owner-read rules already allow it.
Changing
selection retires the old external session immediately; failed writes keep sync
stopped locally until retry. Credentials and per-provider cursors are retained.
Legacy settings without `provider` map to Firebase when enabled, or Sync off when
disabled. Previously connected external accounts remain available to select.
Rules validate the provider and flag together; load the updated rules in the
emulator (and deploy them before releasing these clients).

Native provider authentication returns to the app through the platform SDK or
an authentication session. Web uses a user-initiated popup. Browser tab closure
is best effort. Storage credentials never pass through the backend callback.

## Metadata index

External providers may store `metadata-index-v3.json`, a disposable, HMAC-authenticated
plaintext cache of opaque revision IDs, edit timestamps, encrypted-object references,
keyed fingerprints and provider version tokens. Note text and attachments remain encrypted.
Every page is bound to its filename, account key, library and connection. Authentication is
checked before decoding the inner payload. The current provider listing remains authoritative:
entries are reused only for matching Drive ID/version, Dropbox ID/rev or strong DAV ETags.
Missing/stale entries fall back to original encrypted commits. The cache never changes
inventory, conflict ordering or note/attachment/database formats.

### Linked pages and bounded rewrite cost

The head contains entries and an authenticated `next` reference, or `null` for the tail.
Continuation names are stable: `metadata-index-v3-page-1.json`, `...-2.json`, and so on.
Each file is at most 8 MiB and 4,096 entries; a conservative encoded-size budget can split it
sooner. There is no fixed total entry/page cap. Provider quotas and device resources still
apply. Encoded pages are processed individually, but decoded metadata and page tracking grow
with the library. Historical revisions and tombstones remain indexed while their commits exist.

A loaded or acknowledged page's immutable entries and next link are remembered within the adapter
session. Maintenance compares entry identities and links before encoding; it authenticates and
uploads only changed pages, tail first, updating the head last only
if it changed. A usual tail edit/append rewrites one page; extending a full tail writes that
page's new link plus the new page. Updating a page does not change earlier links. Page-boundary
changes caused by large metadata growth or pruning can still rewrite subsequent pages.
Snapshot partitioning/comparison and decoded memory remain proportional to history size; JSON
encoding, authentication and network writes are limited to changed pages.

Stable page names reuse provider files instead of retaining another chain per edit. After a
library shrinks, unused trailing page slots can remain up to its historical high-water mark;
concurrent Drive creates can also leave duplicate files. These are cache-only and removed by
explicit whole-library cleanup. Normal sync does not delete remote files. Pre-release v1/v2
caches are ignored/rebuilt and removed by explicit cleanup, not migrated or trusted as v3.

### Validation and concurrency

Readers validate each page's MAC, scope, authenticated filename, link syntax and entry uniqueness.
Paths/URLs, cycles, duplicate entries, missing pages and malformed data invalidate the entire
attempted cache load; no partially decoded cache is exposed. Older note clients ignore index
filenames; Drive pages use a separate `indexLibrary` property outside legacy commit queries.

Pages are independently authenticated mutable cache hints, not an atomic inventory snapshot.
An interrupted or competing writer may leave a mixture of individually valid old/new pages.
This is safe only because every entry is checked against current provider version tokens and
its expected commit name before use. Stale/missing entries are read from the original commits;
an invalid/duplicate/cyclic chain falls back as a whole. Changes to this invariant must not
make the index authoritative. Readers may observe fallback work during concurrent updates.

A full scan rechecks a clean remote cache, allowing missing/corrupt pages to be rebuilt without
restarting. If that reload fails, previously authenticated in-memory entries remain available for
lookups against current provider versions; remote page acknowledgements are invalidated, and
republishing waits for a complete validated scan. Missing/stale entries still read their original
commits. Dirty/interrupted snapshots are retained until maintenance finishes; incremental polling
does not reload the cache. Drive tries at most three duplicate candidates per page,
serially, rejecting malformed or unauthenticated copies and pinning only an accepted head. If no
candidate validates, the ordinary commit scan remains the fallback.

Publication requires a successfully loaded chain or a complete scan. Failed cache reads followed
by incremental listings cannot replace a full cache with partial data. Only validated complete
scans prune absent names. Download-only passes never publish. Maintenance follows validated
incoming work and pending note uploads.

Optional writes share five seconds per pass. On failure/exhaustion, acknowledged page contents
and the pending snapshot remain in the adapter for retry after five minutes on a later normal
sync. Unacknowledged pages retry; edits during a pending snapshot remain dirty for a subsequent
snapshot. Restart can require re-uploading pages, but loading a valid chain restores page tracking and
allows unchanged pages to be skipped. Index progress is not a persistent database or upload intent.
Each index read has a 60-second HTTP cap; Drive lookups use 10 seconds. Stricter configured HTTP
timeouts win. Expiry prevents late follow-up requests but cannot undo an already accepted write.
Sanitized debug diagnostics report error types only.

Drive caches the head ID and invalidates it on 404 or cleanup. Explicit whole-library cleanup
accepts only the exact v1 filename, v2 head/hash-page names and v3 head/page names, all with matching
library prefix/property, and re-lists bounded batches until empty. Normal reads/writes accept
v3 names only. Dropbox/WebDAV/Nextcloud clear the same account library directory as before.

## Replication architecture

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
- Schema v13 adds `replica_cursors.checked_notes`: non-null counts mean an
  incomplete listing; null means discovery completed. Upgraded cursors default
  to zero conservatively. Page staging and cursor updates are atomic and the
  upgrade tolerates an already-present column. Completed scans resume downloads
  first; partial scans finish listing for a stable download total. A failed scan
  applies valid staged revisions before reporting its original error, while
  cancelled sessions never start fallback work. Slow partial scans may delay
  first-note availability until discovery completes.
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
- Incoming legacy note/label creation dates without a timezone are retained as
  display metadata; they never establish conflict ordering. Labels with an absent
  creation date use the source revision timestamp, including on publication to
  older clients that reject null. Note and label pull backoff resets only after
  a complete durable pull, not after each successful page.
- Firebase creation dates retain timezone-less wall-clock values; dates with an
  explicit offset represent the same UTC instant. Tests verify that a full Firebase
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
  bootstrap, incremental change cursors, multipart uploads up to its independent
  `multipartUploadBytes` threshold (1 MiB), and resumable uploads above it. Drive duplicate
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
  old-account results. Pausing uploads invalidates in-flight publications while notes, labels and
  ordering retain download access on Free, Lite and Pro. Local edits remain queued.
  The optional `firebaseDownloads` boolean preserves the download source:
  selecting an external provider sets false, selecting `none` retains it in a
  transaction, and explicitly selecting Firebase sets true. Missing legacy
  settings retain built-in download access. Clearing external storage also sets
  false. Rules restrict this preference to the owner and validate its fields.
  No records need backfilling. An already-saved legacy `none` record cannot reveal
  a previous external provider; updated clients cannot reconstruct that history.

- Manual refresh now starts external destinations independently of the Firebase
  note/label attempt and skips Firebase only when its download source is detached.
  Paused Firebase uploads do not suppress download progress, failures, or manual refresh. External refresh waits for
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

- Sign-out checks durable current-revision acknowledgements for the selected
  external destination, including notes, labels, ordering and tombstones. Firebase
  checks include missing queue records, pending/failed/in-flight uploads, label
  deletions and dirty ordering. Paused Firebase does not warn about its queue when
  the selected external destination has acknowledged the library; with no
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
  do not prevent other deletions from uploading. With built-in sync or Sync off, the sign-out check
  recognizes durable Firebase acknowledgements. Verification: 198 focused Flutter tests and
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

## Credential security and device pairing

Provider credentials and account details are encrypted on the client using a
separate HKDF purpose derived from the existing note-encryption master key.
XChaCha20-Poly1305 uses a fresh random nonce for every envelope. Context binds the
user, encryption library, provider, connection generation and OAuth client ID.
Note/media formats and the replica engine are unchanged. The backend stores
ciphertext and capability hashes; it cannot open the new envelopes.

Device pairing and approved-browser persistence follow the shared
[E2EE protocol](E2EE.md#2-adding-a-new-device). QR pairing and the eight-digit
camera-free fallback authenticate the same request-bound handoff. Keep protocol
versions, expiry rules, legacy compatibility and security limitations in that
canonical document rather than duplicating them here.

Firebase coordinates revisions and 60-second refresh leases. The shared Google
exchange function handles code exchange and refresh transiently; other grants
refresh directly with providers. Clients revoke directly with providers. Generations, capability checks, lease fences,
account/device transaction checks and lifecycle guards reject stale writes.
Identical ciphertext retries recover lost registration/refresh responses. A
process crash or prolonged outage during a rotating refresh can still require
fresh consent; no claim is made that provider refresh and Firestore form one
atomic transaction. Revocation cannot erase keys or grants already copied by a
previously authorized device.

Approved browsers retain their encrypted device identity locally. On reload, the
local library opens offline. Cloud transfers and access to the shared provider grant
resume after an online device check. Migration removes only old E2EE key preferences;
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
need the original device online. Reloading an approved browser reuses its device identity.

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
   Verify that an approved browser resumes after reload and that sign-out clears its trust.
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

## Validation and release acceptance

Unit and widget tests cover replica ordering, source/media recovery, provider
isolation, credential lifecycle and sync feedback. The platform integration suite
exercises real SQLite, files and encryption with synthetic provider HTTP. Backend
and pairing tests use isolated demo emulators. Historical run counts and device
session logs are available in Git history; they are not current release evidence.

Verify the following against the release candidate:

- Pair with one QR scan and no return dialog; test the eight-digit camera-free fallback
  and deny camera permission;
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
- Reload an approved browser and verify it restores the
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


## 2026-11-01 download-only sync

For the new client, deploy the required (additive, backward-compatible)
`firebaseDownloads` Firestore-rule support first, then the external-clear
Functions writer, then publish the client. Existing production 1.4.5 (97) can
continue using the updated backend without updating the app; the field is
optional for older writers. See [EXTERNAL_SYNC_QA.md](EXTERNAL_SYNC_QA.md)
for release checks and mixed-version limits.
Device-list presentation is shared through `UserDevicesSection`: three rows in
Account, all rows on the device route, and a quiet main-device removal hint.

The client also fences cached download-permission changes, allows
explicit fail-closed repair of malformed selections, and lets Lite users restore
built-in downloads through a confirmation on the cloud card. Restoration writes
Sync off with downloads enabled; it never enables built-in uploads. The off card
now distinguishes downloads on from all transfers paused. No additional backend
API, secret, data migration or production-app update is required for these fixes.
