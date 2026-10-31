# External sync QA — 24 October 2026

## Lite automatic-update checks

- Passed: 43 focused backend billing tests, including Lite/Pro reconciliation,
  expired access, superseded Apple receipts and Razorpay catalog price validation.
- Passed: 27 Flutter tests for purchase feedback, Lite paywall/entitlements,
  manual versus automatic scheduling, notification batching and bounded retries.
- Passed: 16 replica tests, including notification outbox creation only after a
  successful provider commit and no notification echo when applying remote data.
- Passed: five Firestore rule/integration tests in an isolated `demo-better-keep-signals`
  emulator. Unpaid, expired, wrong-account, stale-connection and extra payloads
  are rejected; same-scope writes are rate limited. Separate authenticated SDK
  clients verified server-committed hint delivery and catch-up for a new listener.
  This checks Firestore transport, not a physical-device sync or store purchase.
- Passed: the Flutter web automatic-update matrix in an isolated Chrome for
  Testing profile with real Auth/Firestore emulators. Two authenticated SDK
  instances and SQLite replicas transferred a table/task/image note, a reverse
  edit and replacement image without manual sync. Background/resume caught up;
  35 seconds idle produced no provider calls or notification echo. Disabling
  automatic access stopped triggers while explicit manual sync still worked.
  Provider HTTP responses were synthetic; this is not physical-device or
  purchased-entitlement acceptance.
- Scoped Flutter analysis has no errors or warnings; one existing style info
  remains in `storage_usage.dart` (`prefer_initializing_formals`).
- Still unverified: real store Lite purchase/restore/plan changes, expiry on a
  device, and two-device automatic external sync with purchased entitlements.
  Catalog drafts and local checks do not prove a production release. No Functions
  or rules deployment, Play activation, or Apple review submission was performed.
- Android tier-change follow-up: 18 focused Flutter checks and 36 backend checks
  passed. A separate Firestore emulator test (five scenarios plus its parent)
  verified atomic token retirement, late-event rejection, predecessor arriving
  after its replacement, pending purchases preserving access, foreign ownership,
  and conflicting successors. Both directions use immediate time credits.
  The native Play checkout and actual credit calculation still need a license
  tester on a Play-installed build; fixtures do not establish those outcomes.

## Confirmed Dropbox blockers

1. The running browser app used `http://localhost:63630/`. Authorization preparation rejected all HTTP origins before opening a popup, producing a generic Reconnect message. The client now permits Dropbox's documented HTTP `localhost` exception; remote origins still require HTTPS. Native callbacks are unchanged.
2. The original localhost test callback was rejected by Dropbox with `invalid_redirect_uri`. The user confirmed that `/oauth/storage/callback` on the configured development origin is already registered. Browser authorization now reuses that URL; Astro serves the static browser receiver there, including requests with OAuth query parameters. Deployment and emulator Hosting configurations use the same static rewrite. No backend token exchange is restored, and no Dropbox console setting was changed.

Historical localhost rejection: `/tmp/betterkeep-dropbox-redirect-error.png`. A synthetic query-bearing request to the public development callback returned HTTP 200 with the browser receiver and `Cache-Control: no-store` after the routing fix.

## Platform matrix

`integration_test/external_sync_platform_test.dart` runs the production replica engine, encrypted file protocol, Dropbox transport, platform SQLite implementation, and platform file system. Three isolated replica databases share a **synthetic Dropbox HTTP boundary**. This is not proof of real Dropbox OAuth, CORS, quota behavior, or transfers between separate physical devices.

The matrix covers:

- Text, table cells and checked/unchecked tasks, with image, audio-byte and sketch-source attachments.
- Six alternating replica edits, verifying exact rich content and media after each edit.
- Replacing an existing media file and synchronizing the new bytes.
- Restoring a clean replica without previous files or cursors.
- Repeated synchronization without additional uploads after convergence.
- Deletion propagation to both receiving replicas.
- Hydrating a downloaded sketch and generating/decoding its preview with the real platform renderer.

The audio fixture verifies byte preservation, not recording or playback. The test does not automate editor gestures. Test databases and media use unique directories; no personal library or provider files are used.

| Target | Initial matrix | Preview extension |
| --- | --- | --- |
| iOS 26.5 simulator, fresh Better Keep Sync QA device | Passed | Passed |
| Android API 36 emulator, new temporary image/data partition | Passed after startup connection retry | Passed |
| Web, Codex browser with actual web SQLite/file storage | Passed after correcting the test harness's web database options | Passed |

Logs: `/tmp/betterkeep-qa-ios.log`, `/tmp/betterkeep-qa-android-matrix-retry.log`. Preview logs: `/tmp/betterkeep-qa-android-preview.log`, `/tmp/betterkeep-qa-ios-preview.log`. Web pass markers and final success were saved to `/tmp/betterkeep-qa-web-matrix-results.json`. Full regression log: `/tmp/betterkeep-qa-full-suite.log`.

## Regression checks

- Browser authorization/settings suite: **27 passed**, using Flutter's isolated Chrome test instance. Includes synchronous popup opening, closed/blocked popup handling, localhost callback, and insecure non-local origin rejection.
- Sync/media/encryption/transport regression suite: **77 passed**.
- Focused Dart analysis and whitespace checks passed, including the preview extension.
- Complete Flutter suite: **1,501 passed, one web-only case skipped**. Browser-specific checks ran separately above.
- Callback/proxy routing regressions: **3 passed**, including the public debug origin, query-bearing callback selection and both static Hosting rewrites. Development runner tests: **17 passed**. Browser authorization/settings tests after the stable callback change: **27 passed**.

## Real Dropbox browser check

- The HTTPS development app signed in successfully through the emulator proxy
  with a fresh synthetic account, separate from existing libraries.
- Dropbox authorization completed using the existing registered callback and
  the user-authorized provider account. The connection dialog closed, Dropbox
  became the selected provider, and its details showed successful sync.
- Created a test note with an app-logo image attachment and a two-by-two table.
  The image rendered in the editor and note-card preview. The account page
  showed one note and one media item. Dropbox details reported a subsequent
  successful sync at 2:45 PM. This establishes the app-reported upload result,
  not an independently verified download on another device.
- The browser automation could not enter rich-editor body/cell text through
  Flutter's semantics controls; typed table values and tasks are not claimed
  as live-UI tests. The earlier synthetic platform matrix covers their codec.
- A normal new tab was exposed by the Codex browser, while a window using the
  `popup` feature was not exposed to its automation inventory. Authorization
  now requests a normal tab; all four focused browser authorization tests pass.
  The live Dropbox connection above completed with the earlier popup build;
  the changed tab presentation has not yet completed a fresh provider flow.
- A fresh build on a second local origin loaded, but cross-origin HTTPS fetches
  to the development proxy failed in the Codex browser. Credential-free GET
  and POST probes also failed there, although command-line OPTIONS and POST
  checks returned matching CORS headers. That second browser origin remained blocked at sign-in; physical-iPhone
  pairing and Google Drive shared-grant restoration were later verified below.

## Real Google Drive: physical iPhone and web

Tested through Device Hub on a physical iPhone 15 running iOS 27.0 and the
existing Codex browser QA session, using the isolated Firebase emulator account.
Google authorization used the provider account explicitly authorized by the user.

- Physical-device emulator sign-in succeeded with the LAN address entered in
  the debug screen. The build-time host no longer overrode that address.
- Approved the iPhone by comparing all 32 characters on both devices, then
  comparing the reverse confirmation code before accepting the key. The web
  scanner reported an unavailable camera and exposed the code fallback.
- Native Google authorization opened, selected the authorized account, returned
  to the app, and closed the connection dialog. Drive became the sole selected
  provider. No new consent screen appeared for this existing Google grant.
- The browser automatically received the encrypted Drive connection and selected
  it without a second Google sign-in.
- Created `Drive QA physical iPhone` on iPhone with body text and a checklist;
  it appeared on web through Drive. Added a sketch, then additional visible
  marks; the web editor eventually showed the latest preview. An earlier
  preview was visible while synchronization was still in progress.
- Renamed the note to `Drive QA edited on web`, completed its checklist, and
  inserted a two-by-two table on web. All three changes appeared on iPhone.
- Entered `Drive table verified` in the first table cell on iPhone and verified
  that exact text in the browser's received note.
- The existing image-and-table QA note also appeared on iPhone. Because Dropbox
  was selected briefly before Drive, that initial transfer is not attributed
  exclusively to Drive. The fresh Drive note above establishes real Drive
  transfer independently.
- Web details reported successful Drive sync at 3:32 PM; iPhone details reported
  successful Drive sync at 3:33 PM. No reconnect prompt was needed on web.

Observed UX issue: the trusted browser's manual verification confirmation dialog
remained open after the iPhone unlocked and was closed manually. The live browser
was the earlier running build; this observation does not establish whether the
latest source still has that issue. One-scan pairing was not exercised here.

These checks establish live authorization, shared connection restoration,
bidirectional note edits, checklist/table content, and sketch transfers/previews.
They do not establish token-expiry refresh, offline/concurrent conflict behavior,
audio/video playback, deletion propagation, or reconnect/account-switch recovery.

## Remaining acceptance gates

HTTPS emulator follow-up: a credential-free browser probe confirmed that Auth
responds from a localhost page but fails from the HTTPS development page in the
Codex browser. `EMULATOR_HOST` now overrides platform defaults, and the optional
`EMULATOR_WEB_ORIGIN` routes the four browser emulator services over HTTPS.
The same origin setting enables the Astro routes. The user authorized
keeping them enabled for testing; the HTTPS origin is persisted
in the root `.env`, and the Auth emulator responds through the public HTTPS route.
Host/backend tests (17), existing banner tests (7), transport/environment tests
(6), and callback/proxy routing tests (4) passed. Successful HTTPS emulator
login and real Dropbox authorization are recorded above; the broader
cross-device acceptance gates below remain open.

- Repeat authorization with the new regular-tab presentation, and verify token
  refresh and encrypted grant restoration on a second actual device. Device Hub now provides physical-iPhone UI access; real Drive OAuth was
  exercised above. The automated simulator matrix still does not replace
  real-provider OAuth on each platform.
- Run real-provider cross-device edits, concurrent/offline edits, media updates and playback, preview repair, deletion, disconnect/reconnect, browser reload/reapproval, and account switching.
- Google initial authorization on Android/web remains the documented product limitation: those platforms consume an existing reusable grant created on Apple or desktop.

No deployment, production record cleanup, existing secret deletion, commit, or push was performed.

## Repeat the platform matrix

```sh
flutter test integration_test/external_sync_platform_test.dart -d DEVICE_ID
flutter run -d web-server --web-port=63742 --target integration_test/external_sync_platform_test.dart
```

Open the second command's URL in an isolated browser. A successful run prints each `SYNC QA PASS` marker followed by `All tests passed`. It needs no provider credentials or Firebase service. For the real app, use the regular development runner with `.env` and select Firebase Emulator.

### Automatic-update emulator matrix

Use a matching Chrome for Testing / ChromeDriver pair; set `CHROME_BINARY` and
`CHROMEDRIVER_BINARY` to their executable paths if they are not the defaults.
The runner creates a separate temporary browser profile. From the repository root:

```sh
node_modules/.bin/firebase emulators:exec \
  --only auth,firestore --project demo-better-keep-signals \
  --config firebase.automatic-sync-test.json \
  'GCLOUD_PROJECT=demo-better-keep-signals node functions/test/support/seedAutomaticSync.cjs && node tool/run_flutter_web_integration.mjs integration_test/external_sync_platform_test.dart --dart-define=AUTOMATIC_SYNC_EMULATOR_TEST=true'
```

Build Functions first if `functions/lib` is absent or stale. This matrix uses two
authenticated Firebase SDK instances, separate platform SQLite databases, the
production scheduler and replica engine, and a synthetic encrypted Dropbox HTTP
boundary. The seed helper refuses non-demo or non-loopback emulator configuration.
It exercises automatic rich-note/media transfer in both directions, background
catch-up, idle behavior, and manual sync after disabling automatic access.
It does not exercise provider OAuth, a store purchase, or two physical devices.


## Storage capacity and OTP clearing — local validation

The current changes passed **195 Flutter tests** (one web-only case skipped in
that VM run), **30 tests in Flutter's isolated headless Chrome instance**, and
**19 backend tests**. Project-wide Flutter analysis and whitespace checks passed.
The browser cases use synthetic provider HTTP boundaries; no provider account
files were deleted and no verification email was sent by this test run.

Coverage includes full-storage status and explicit retry, Free labels, narrow
settings layouts, OTP confirmation UI, incorrect/expired/replayed codes, five
attempts, resend cooldown, provider/account authorization, refresh-lease exclusion,
interrupted deletion remaining disabled, cleanup retry, exact library-only deletion,
foreign Drive object rejection, namespace isolation, and unchanged version-2 paths.
Firebase compatibility fixtures cover legacy payload reads/merge writes, timestamp
identity, old boolean selection, media dependencies, and offline commit retries.

Before release, still verify SMTP delivery and real provider cleanup on disposable
test libraries, real quota failures, concurrent physical devices during clearing,
resuming local notes after clearing, and an old released Firebase client paired
with the updated client/backend. The new cleanup Functions require deployment;
no deployment or live cleanup was performed as part of this change.

## Generic WebDAV validation — 2026-10-24

- Focused Flutter regression set: 118 passed, one browser-only case skipped on the VM.
- Isolated Chrome test profile: 48 passed (DAV transport, encrypted credential broker, provider settings UI).
- Backend ciphertext registration/capability/reset tests: 11 passed; TypeScript build passed.
- Scoped analysis of the changed implementation and new DAV fixtures: no issues.
- All DAV requests used in-memory HTTP fixtures. No live WebDAV account, physical-device
  transfer, hosted-server CORS configuration, or production deployment was exercised.

## Shared Google OAuth exchange — 2026-10-26

- Installed the updated debug APK on the authorized physical Samsung QA phone.
  The user completed Google Drive authorization on Android.
- The already-approved Codex browser received that connection, displayed Drive
  storage usage, and downloaded `QA Drive Test` with its text and rendered sketch.
  No Google sign-in was completed in the browser.
- Changed the title in the browser to `QA Drive Test - browser round trip` and
  manually synced. The browser reported a successful sync. The user confirmed
  that Android received the changed title with the sketch intact after manual fetch.
- Local exchange/refresh security and credential-service tests passed (16 tests).
  Controller regression tests passed (22 tests), including clearing an old error
  when a new connection arrives from another device. Focused analysis passed.
- Automated encrypted-grant tests cover restoration on another device/browser
  session, expired access-token refresh, concurrent refresh and rotated-token
  persistence. These use synthetic HTTP boundaries; the live check above did not
  wait for Google access-token expiry or exercise long-term provider revocation.
- Android debug build passed. New exchange behavior on iOS/macOS/Windows/Linux
  remains to be exercised on those platforms. No production deployment occurred.
