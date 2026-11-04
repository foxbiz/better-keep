# Website and web app releases

All clients use `https://betterkeep.app/app/`. The Hosting launcher offers beta before
it downloads beta code. “Not now” loads stable and dismisses the offer for that tab.
Accepting remembers the beta channel in that browser profile. The backend is shared:
changes to synced notes and account actions affect the live account.

## Commands

| Command | Website | Web app |
| --- | --- | --- |
| `npm run deploy hosting-web` | Build current website | Preserve all live app files |
| `npm run deploy hosting-app-beta` | Preserve live website | Build and offer a new beta |
| `npm run deploy hosting-app-prod` | Preserve live website | Promote the currently published beta |
| `npm run deploy hosting-beta` | Build current website | Build and offer a new beta |
| `npm run deploy hosting-prod` | Build current website | Promote the currently published beta |

These replace the public `hosting` and `hosting-public` targets.
They target only the public `better-keep-notes` site. They do not publish admin Hosting,
Functions, database rules, indexes or Storage rules. `backend` and `indexnow` remain
separate commands. `npm run deploy hosting-admin` builds and validates `build/admin`, then
publishes only `hosting:admin`; it accepts no scope/project overrides. The old
`hosting-admin-preview` alias has no replacement here. Admin publication requires separate
approval and does not use the public snapshot/overlay runner. The existing `npm run build web` remains a local combined build.

Running a deployment command without options **publishes** after preparing successfully.
An agent must obtain explicit user approval before running that publishing step.
For review first, use the same target with `--prepare-only`:

```sh
npm run deploy hosting-beta -- --prepare-only
```

This reads public Hosting metadata/files and builds locally; it does not publish or
query application databases. It prints a unique prepared directory under
`build/hosting-releases/`. Review its `release.json` (scope, baseline version, changed
paths and hashes), then serve its `public` directory:

```sh
node tool/serve_beta_preview.mjs build/hosting-releases/PRINTED_DIRECTORY/prepared/public 5102
```

After approval, publish that exact prepared directory:

```sh
npm run deploy hosting-beta -- --publish build/hosting-releases/PRINTED_DIRECTORY/prepared
```

Use the same target for preparation and publication. A target mismatch, edited artifact,
failed upload or changed live release aborts publication. No `--only`, project, config or
arbitrary Firebase overrides are accepted by these Hosting commands.

## How scoped deployments work

Firebase Hosting releases replace a complete site's file inventory. The runner therefore
captures and verifies the entire live site, then overlays only the requested scope.
Website-only releases preserve every `/app/` file; app-only releases preserve every file
outside `/app/`. Previously published `/app/releases/` assets are always retained unchanged,
so existing tabs can still fetch their dependencies. Older website assets are retained too.
The runner checks these invariants before creating the review report.

Live Hosting configuration is carried forward, including function rewrites and pinned
Cloud Run tags. Website releases update the standalone storage OAuth callback and its
matching CSP; app releases update only app cache headers. Neither operation deploys the
referenced backend services. The callback needs a website or combined release if it has
not yet been published; an app-only release cannot install a new root callback.

Publication uses the pinned Firebase CLI's authentication/uploader and the Hosting API,
retaining the live API configuration without converting or retargeting backend rewrites.
It checks the live baseline before uploading and immediately before releasing. A local
lock prevents concurrent operations from this checkout. Hosting does not offer an atomic
compare-and-release here: avoid simultaneous deployments from another machine or CI.
An interrupted process can leave `build/hosting-releases/.lock`; remove it only after
confirming no release process is still running. Failed snapshots lack a completion manifest.

## Beta builds and promotion

A beta command generates a unique release ID and compiles two clients from the current
source and build environment. Keep app sources and dependencies unchanged while the
paired builds run:

- `/app/releases/ID/`: beta browser storage and Firebase session identity.
- `/app/releases/ID/stable/`: the same source using existing stable storage/session identity.

Both variants are uploaded in the beta release. The normal stable client is not replaced
at that point. SQLite workers use stable URLs per storage group: `/app/sqflite_sw.js` for
stable, `/app/beta-runtime/v1/sqflite_sw.js` for beta. Stable retains the default worker
protocol because the deployed worker predates configurable options. The document base
stays `/app/`; Flutter’s bootstrap config resolves versioned assets explicitly. This keeps concurrent releases on
one shared worker per database. Beta runtime bytes are retained unchanged; a dependency
change that alters the worker or SQLite Wasm is rejected pending an explicit storage
compatibility review. Clients without SharedWorker support still require separate
multi-tab validation; this does not add cross-tab locking to the dependency’s fallback.

A production command requires an unpromoted live beta with its stable companion. It
changes the release manifest, without rebuilding app source or changing release assets:

| Browser | After promotion |
| --- | --- |
| Existing stable or new browser | Stable companion; stable local storage and Firebase session |
| Existing beta browser | Same beta-storage build; its local data/session remain in place |

The offer and Beta badge disappear for the promoted release. No notes, keys, preferences
or auth sessions are migrated or deleted. A future beta command retains the last promoted
stable pointer: declining loads that version, not the original legacy app. Beta opt-in
persists, so previous testers receive subsequent beta releases when they next load the app.
Already-open tabs are not forcibly refreshed.

Browsers remember the release sequence once they start a versioned client. Missing or
older manifests fail closed instead of silently starting an older app against newer data.
Do not remove the launcher, clear the beta choice, or clear site data to “finish” promotion.
The older local preview build without a stable companion cannot be promoted; publish a
new paired beta first.

### Leaving beta deliberately

First sync or export any unsynced beta notes, and close other app tabs. Beta and stable use
separate local databases, so unsynced beta changes will not appear in stable automatically.
For a deliberate opt-out, open the app origin's browser console and run:

```js
localStorage.removeItem("betterkeep.web.channel.v1");
location.reload();
```

Choose “Not now” if the beta offer appears after reloading. This keeps beta notes/keys and the anti-downgrade sequence; it does not clear site data or
migrate notes. A later beta opt-in can reopen the isolated beta storage. Do not use this as a
promotion step or to bypass a rejected/missing release manifest.

## Storage and rollout checks

Beta isolates preferences (`flutter.beta.`), SQLite (`better_keep_beta_sqlite`), attachment
storage (`better_keep_beta` OPFS directory or `beta_better_keep_fs` IndexedDB), Firebase
app identity (`better-keep-beta`) and OAuth transaction session keys. Stable/native defaults
remain unchanged. Same-origin storage separation is not a security boundary.

Before publication, review both build variants, real provider OAuth redirects, existing
sessions, unsynced notes, multiple open tabs and installed-PWA upgrade/offline behavior.
Previously installed service workers may continue serving an older launcher until updated;
beta bundles do not register a new Flutter service worker. Local Chrome checks do not prove
Safari, device, real OAuth or production sync behavior.

The local preview server blocks production backend connections with CSP. It supports
synthetic OAuth popup handoff, not a completed provider login. The normal dev website
proxies `/app` to Flutter on port 63630, bypassing the launcher. To review a prepared
bundle through an existing dev tunnel, keep the preview server running, stop the existing
website dev process and restart it with:

```sh
BETTER_KEEP_FLUTTER_DEV_ORIGIN=http://127.0.0.1:5102 npm run dev hosting
```

This changes only the local upstream; it does not change DNS or deploy Hosting.

## Recovery

Keep the prepared directory, its baseline snapshot, and the previous Hosting release.
A Hosting rollback does not roll back browser databases or cloud writes. Once users have
run a newer client, prefer a forward fix with a new release sequence. Restoring an older
manifest deliberately stops upgraded browsers rather than risking a silent downgrade.
Do not delete retained releases or browser data as a recovery shortcut.

## Release and artifact safeguards

Versions are created with `CREATED`, uploaded, then finalized with the prepared config.
The runner reads back `FINALIZED` and compares the complete config before publishing.
Any difference blocks release. The create API accepts config too; the earlier sequence was
not proven invalid, but matching the CLI sequence and checking read-back removes that assumption.
A disposable live Hosting acceptance run is still required before first production use.

Website overlays validate visibility on the assembled inventory. App compatibility checks
belong to app builds; admin bundle validation belongs to `hosting-admin`. Website-only
publication intentionally does not rebuild or revalidate unrelated preserved app binaries.
The known legacy callback header glob is split so `/app/storage-auth.html` retains its policy
while updated root callback paths receive one current CSP and `Referrer-Policy: no-referrer`.
Arbitrary unrelated wildcard policies are preserved; inspect overlapping custom policies in
the prepared config rather than removing them broadly and changing other routes.

Local `build/hosting-releases/` snapshots and prepared artifacts are not automatically removed.
Keep the current prepared release and its baseline through acceptance/rollback. After confirming
no release/preview process uses an older directory, remove only that obsolete local directory.
Never delete remote `/app/releases/` assets as part of local cleanup. A stale `.lock` may be
removed only after checking that no release process is running. No automatic age-based cleanup
is enabled, because it could remove a reviewed artifact awaiting publication.

## Local validation

The `web-release` and full `release` gates include both browser regression files below.
Browser fixtures use a temporary headless profile. Set `CHROME_BIN` to the installed Chrome
executable outside macOS; the Auth fixture also accepts `CHROME_EXECUTABLE`.

```sh
node --test test/tool/hosting_release_test.mjs test/tool/deploy_tasks_test.mjs test/tool/beta_web_test.mjs
node --test test/web/beta_launcher_test.mjs
flutter test --platform chrome test/web_storage_recovery_test.dart
# Use an assembled paired-beta fixture in build/; its manifest is restored afterward.
node tool/test_hosting_promotion.mjs build/hosting-releases/PRINTED_DIRECTORY/prepared/public
node tool/test_beta_preview.mjs http://127.0.0.1:5102
node tool/test_beta_preview.mjs http://127.0.0.1:5102 --indexeddb-fallback
```

Fixture tests cover all five scopes, exact promotion bytes, subsequent betas, invalid
companions, stale baselines, edited artifacts, failed uploads and concurrent-release
rejection. Browser tests cover consent, mobile layout, loading, promotion routing,
retained beta choice, missing/older manifests and synthetic OAuth callback handoff.
No production deployment or database change was performed while implementing these commands.

The compiled promotion check also exercises an attachment across reload. It exposed a
pre-existing OPFS bug: listing a missing directory returned root entries to cache cleanup.
The web file system now returns an empty list for missing directories and full child paths,
matching the native contract; a browser regression test protects unrelated attachments.

Validated locally on 2026-11-02: 36 tooling tests, seven launcher browser tests, four
Flutter browser storage tests, both release builds, focused Flutter analysis, and the
compiled promotion check passed. The latter verified retained beta preferences and
attachment, separate Firebase/SQLite identities, shared beta worker across tabs, and
successful stable startup using the captured deployed worker. Live publication, real
OAuth/account sync, Safari and installed-PWA upgrades remain untested.


The release gate now compiles channel namespace assertions with both `WEB_BETA=true`
and `false`. The paired-build runner regression checks both defines, both worker builds
and generated stable/beta metadata using fixture build outputs. These checks do not replace
an actual paired release build and same-origin IndexedDB/OPFS/preferences coexistence test.
Browser tests accept `CHROME_BIN`, `CHROME_BINARY` (CI), or `CHROME_EXECUTABLE`.
Admin builds write directly to `build/admin`; the admin deploy task validates that artifact
before publishing and verifies the deployed dashboard afterward. No Hosting comparison
bypass is provided: configuration read-back differences still stop release safely.
