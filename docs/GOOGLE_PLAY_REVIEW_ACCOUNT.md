# Google Play review account runbook

The review login still uses Firebase email/password authentication. The
review-only local session is enabled only when the authenticated user is
`review@betterkeep.app` and its Firebase ID token contains the signed boolean
claim `appReview: true`.

## Emulator testing

Creating `review@betterkeep.app` in the Authentication Emulator UI is not
enough: review mode also requires the signed `appReview: true` custom claim.
With the emulator suite running, prepare or reset the local account from a
second terminal:

```sh
cd functions
read -s "REVIEW_ACCOUNT_PASSWORD?Emulator review password: "
echo
FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 \
FIREBASE_STORAGE_EMULATOR_HOST=127.0.0.1:9199 \
FUNCTIONS_EMULATOR=true \
GCLOUD_PROJECT=better-keep-notes \
REVIEW_ACCOUNT_PASSWORD="$REVIEW_ACCOUNT_PASSWORD" \
npx tsx scripts/resetReviewAccount.ts --execute
unset REVIEW_ACCOUNT_PASSWORD
cd ..
```

Sign out of the app after changing claims, then sign back in through **Login
with Email** so Firebase issues a fresh token. The emulator host variables are
required; do not run the reset script against the emulator without them.

## 1. Validate the release

From the repository root:

```sh
npm run release
npm test firebase-rules
npm test firebase-emulator-functions
npm test firebase-emulator-review
flutter analyze
flutter test
npm test functions
```

The Android debug and release builds must also succeed before distributing the
review credentials:

```sh
flutter build apk --debug --dart-define-from-file=.env
flutter build appbundle --release --dart-define-from-file=.env
```

Do not continue if any command fails.

## 2. Deploy the protected backend

Deploy Functions and both rulesets before releasing the app or distributing
the review password:

```sh
npm run functions build
npm run deploy backend
npm run firebase indexes
```

Before deploying Functions for the first time, provision a 32-byte OAuth state
secret with Firebase Secret Manager as `OAUTH_STATE_SECRET`. Never store the
secret in `.env`, source control, or the runbook.

The v2 client never downgrades, but the backend temporarily accepts released
v1 clients. Keep `OAUTH_LEGACY_V1_ENABLED=true` for no more than one client
release or 30 days. Set it to `false` earlier when v2 accounts for at least 99%
of custom-OAuth starts for seven consecutive days. Monitor only the structured
`oauth_flow_started`, `oauth_flow_completed`, and `oauth_flow_failed` fields;
those events intentionally contain no UID, email, code, verifier, or token.
At day 30, disable v1 regardless of the remaining volume and require affected
clients to update.

The old remotely callable reset function is no longer exported. Confirm it was
removed by the Functions deployment; if it remains, delete only that legacy
function:

```sh
node tool/firebase_cli.mjs -- \
  functions:delete resetReviewAccount --region us-central1 --force
```

Do not release a client that depends on this isolation before all three backend
deployments are active.

## 3. Rotate and prepare the review account

Use a new strong password. Production execution uses Firebase Admin Application
Default Credentials. Store an approved, least-privilege service-account JSON
outside the repository and point `GOOGLE_APPLICATION_CREDENTIALS` to its
absolute path. The credential's `project_id` must be `better-keep-notes`.

First run the default dry-run. It validates the project, named database, bucket,
credentials, and reports cleanup counts without changing data:

```sh
cd functions
export GOOGLE_APPLICATION_CREDENTIALS="/absolute/path/to/approved-service-account.json"
npx tsx scripts/resetReviewAccount.ts \
  --project=better-keep-notes \
  --database=better-keep
```

Then read the password without adding it to shell history and execute. The
script asks you to type `better-keep-notes/better-keep` before it mutates
production:

```sh
read -s "REVIEW_ACCOUNT_PASSWORD?New review password: "
echo
export REVIEW_ACCOUNT_PASSWORD
npx tsx scripts/resetReviewAccount.ts \
  --execute \
  --project=better-keep-notes \
  --database=better-keep
unset REVIEW_ACCOUNT_PASSWORD
unset GOOGLE_APPLICATION_CREDENTIALS
```

The script disables the identity, revokes old sessions, unlinks every federated
provider, removes cloud data and storage, rotates the password, verifies the
email, grants a long-lived Pro entitlement, sets `appReview: true`, and only
then re-enables the identity. It retains the existing UID and is safe to rerun.
If a step fails, the identity stays disabled until a successful rerun. The
script never prints the password.

Do not pass the password as a command-line argument and do not commit it to the
repository.

## 4. Build and verify the app

Build the exact release artifact intended for Google Play. Test it on a device
that has never used the review account, or clear the app's storage first.

Required checks:

1. Wrong password is rejected by Firebase.
2. The review email and rotated password open Notes directly.
3. No device approval, Start Fresh, OTP, recovery, or recovery-key page appears.
4. Create, edit, close, reopen, and delete a local note.
5. Force-stop and reopen the app; it must return to Notes without a prompt.
6. Install on a second clean device and repeat the login while the first device
   remains signed in.
7. Confirm connected accounts, subscription management, deletion, recovery,
   Start Fresh, and secure cloud-link sharing are absent.
8. Confirm local text/Markdown sharing still works and local notes survive an
   app restart.
9. Confirm an ordinary account still follows its existing E2EE and recovery
   flow.

## 5. Update Play Console App access

Store the rotated password only in Play Console's **App access** credentials.
Use these instructions (under 500 characters):

```text
1. On the Welcome screen, tap Login with Email.
2. Enter the email and password provided in App access, then tap Sign In.
3. The review account opens the Notes screen directly. No OTP, device approval, Start Fresh, or recovery-key setup is required.
```

Save the App access changes, upload the verified release, and use **Publishing
overview → Send for review**.

## Dependency audit policy

`firebase-tools` is intentionally pinned to `15.24.0`. On 2026-07-28, the root
full audit reported 19 development-only advisories (3 moderate, 16 high) in the
Firebase CLI dependency tree, while the release gate remained clean:

```sh
npm run release
# found 0 vulnerabilities
```

Do not apply npm's suggested forced downgrade to `firebase-tools@14.23.0` and
do not add transitive overrides for the CLI. Whenever the pinned Firebase CLI
version changes, rerun both `npm audit` and `npm audit --omit=dev`, update this
baseline, and rerun every emulator suite.

The Functions package pins patched, Node 22-compatible transitive releases for
`protobufjs`, `uuid`, and `@tootallnate/once`. Both runtime audits must remain
clean:

```sh
npm run check audit
# found 0 vulnerabilities
```

Do not remove those Functions overrides without rerunning the Functions build,
unit suite, both emulator suites, and both audits.
