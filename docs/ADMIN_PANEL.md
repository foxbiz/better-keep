# Better Keep administrator portal

The private portal is an isolated static application at `https://admin.betterkeep.app/`. It uses the existing Firebase project and Authentication tenant, but it is deployed from `build/admin` to a separate Hosting site. Public Hosting must return `404` for `/admin` and must never contain the administrator bundle.

## Required Firebase configuration

1. Enable Firebase Authentication with Identity Platform and enable TOTP MFA.
2. Create the secondary Hosting site and apply the checked-in targets:

   ```sh
   node tool/firebase_cli.mjs -- hosting:sites:create better-keep-notes-admin --project better-keep-notes
   ```

3. Link the Hosting site to the existing Firebase Web App, add `admin.betterkeep.app` as an authorized Auth domain, and map the custom domain in Firebase Hosting.
4. Register `admin.betterkeep.app` with reCAPTCHA Enterprise App Check. Put the public site key in `admin-site/.env` as `PUBLIC_ADMIN_APP_CHECK_SITE_KEY` before building.
5. Provision `admin@betterkeep.app` as a dedicated verified password account. Put its UID in the deployed Functions environment as `ADMIN_ACCOUNT_UID`. Do not use an everyday application account.

Admin callables enforce App Check, the configured UID, verified email, the password provider, the `appAdmin` claim, and a TOTP second-factor claim. Mutations additionally require authentication from the previous 15 minutes and consume limited-use App Check tokens.

## Identity bootstrap and recovery

The bootstrap script is dry-run by default and requires an explicit target plus interactive confirmation before changing production Auth state.

```sh
cd functions

# Inspect, then grant the dedicated identity.
ADMIN_ACCOUNT_UID=<uid> npm run admin:bootstrap -- \
  --action=grant --email=admin@betterkeep.app
ADMIN_ACCOUNT_UID=<uid> npm run admin:bootstrap -- \
  --action=grant --email=admin@betterkeep.app \
  --execute --project=better-keep-notes --database=better-keep

# After portal enrollment, fail closed unless TOTP and the claim are present.
ADMIN_ACCOUNT_UID=<uid> npm run admin:bootstrap -- \
  --action=verify --email=admin@betterkeep.app

# Remove access from a former identity and revoke its tokens.
npm run admin:bootstrap -- \
  --action=revoke --email=<former-account> \
  --execute --project=better-keep-notes --database=better-keep
```

For TOTP loss, use Firebase Console or a locally authenticated Admin SDK session to remove the lost factor, revoke refresh tokens, and repeat enrollment. There is intentionally no browser bypass or recovery code stored by the portal.

## Data bootstrap and revenue pipeline

Set the Play Console financial report bucket in `functions/.env`. Both legacy
`pubsite_prod_<id>` and newer `pubsite_prod_rev_<id>` bucket names are accepted,
as either the Console URI or bare bucket name:

```dotenv
GOOGLE_PLAY_REPORT_BUCKET=gs://pubsite_prod_7966583793961491942
```

`admin:backfill` remains dry-run by default. Execution rebuilds the backend-only user index, writes `totalUsersUpdatedAt`, and enqueues verified Razorpay payments through `adminRevenueEvents`; it does not directly rewrite revenue totals.

```sh
cd functions
npm run admin:backfill
npm run admin:backfill -- \
  --execute --project=better-keep-notes --database=better-keep
```

Revenue events are leased and processed idempotently. Failed events retry with capped exponential backoff; the tenth failure becomes `dead_letter` and appears in the portal. Before launch, require zero pending, retrying, and dead-letter events after the backfill.

The billing reconciliation command validates live Razorpay payments and
refunds, verifies every known Play token, enumerates every available Play sales
report, and uses the Orders API to recover purchase tokens. It reports without
writing by default. Execution quarantines unverifiable ledger entries, imports
refunds through the durable outbox, reconciles user claims, and rebuilds gross,
refund, and net summaries from verified production transactions.

The command completes a read-only provider preflight before its interactive
execution prompt. Razorpay `400` and `404` responses are reported as hashed,
record-specific review items and never change access. Credential, permission,
rate-limit, network, and provider-service failures stop execution before any
writes. Firebase UIDs are verified during the same read-only audit; subscriptions
owned by deleted accounts become stable `razorpay_owner_missing` review issues
and are not normalized or reconciled. The `all` provider mode authoritatively
reconciles only Google Play and Razorpay. Existing App Store records are listed
as `stored_only` and remain unchanged because they require a signed App Store
notification, purchase verification, or restore flow.

```sh
cd functions
npm run admin:reconcile-billing
npm run admin:reconcile-billing -- \
  --execute --project=better-keep-notes --database=better-keep
```

For a Google Play-only audit or repair, use the isolated command below. It
does not load Razorpay credentials or process Razorpay records/events.

```sh
npm run admin:reconcile-play
npm run admin:reconcile-play -- \
  --execute --project=better-keep-notes --database=better-keep
```

The reconciliation launcher loads non-secret configuration from
`functions/.env`, uses Application Default Credentials to read
the selected provider credentials directly from Google Secret Manager, and
passes them only to the child process. It pins the ADC quota project and uses
explicit quota-project Identity Toolkit requests for its read-only Auth
preflight and claim synchronization. The Play-only command reads only
`GOOGLE_PLAY_CREDENTIALS`; the combined command also reads `RAZORPAY_KEY_ID`
and `RAZORPAY_KEY_SECRET`. It never writes or prints secret values. The dry-run
output uses a short hash instead of a raw Play purchase token and lists each
subscription's stored and resolved Firebase UID, authoritative state, renewal,
expiry, environment, account match, effective entitlement, and classification.

Google Play Console aggregate subscription charts are not entitlement data.
They may count trials, and a canceled subscription leaves the active metric
even when the user retains access until the authoritative expiry. Never grant
or revoke access from those aggregate counts.

Review every `adminSubscriptionIssues` record after execution. A purchase must
either be linked to the exact Firebase UID supplied to Google as the
obfuscated external account ID or remain unresolved without granting access.

## Razorpay webhook-secret rotation

Razorpay API calls continue to use `RAZORPAY_KEY_ID` and
`RAZORPAY_KEY_SECRET`. Webhook signatures use a separate secret and must never
be configured in `functions/.env` or browser build variables.

For a zero-downtime migration, retrieve the webhook's current secret from the
existing secure operational store, generate a new independent secret, and set
both values in Google Secret Manager without printing them in shell history:

```sh
node tool/firebase_cli.mjs -- functions:secrets:set RAZORPAY_WEBHOOK_SECRET_PREVIOUS --project better-keep-notes
node tool/firebase_cli.mjs -- functions:secrets:set RAZORPAY_WEBHOOK_SECRET --project better-keep-notes
```

Set `RAZORPAY_WEBHOOK_SECRET_PREVIOUS` to the currently active dashboard
webhook secret and `RAZORPAY_WEBHOOK_SECRET` to the new value. Deploy the
backend while the dashboard still uses the previous value, then update the
live Razorpay webhook to the new value and send a test event. The Function
temporarily accepts either signature but continues to use only
`RAZORPAY_KEY_SECRET` for provider API requests.

After 48 hours with successful deliveries and no failed revenue events, remove
the previous-secret binding from the Function, deploy the backend again, and
disable the old secret version. Do not remove the fallback before checking
Razorpay's webhook delivery log and the `razorpayWebhookEvents` collection.

## Deployment and verification

Deploy backend resources before Hosting so MFA/App Check enforcement, indexes, audit reconciliation, and outbox workers exist when the portal becomes reachable.

```sh
npm run deploy backend
npm run deploy hosting-admin-preview
npm run deploy hosting
```

The production Hosting command deploys `hosting:public,hosting:admin`. Individual `hosting-public` and `hosting-admin` targets are available for recovery. Do not deploy the administrator site if `PUBLIC_ADMIN_APP_CHECK_SITE_KEY` or `ADMIN_ACCOUNT_UID` is missing.

Run the release gate and verify:

- Public `/admin` is a 404 and contains no `data-admin-root` markup.
- Admin HTML is `no-store`, `noindex`, and served with the strict CSP in `firebase.deploy.json`.
- Password sign-in requires TOTP and closing the browser session clears Auth persistence.
- A disable/revoke action creates a durable audit record before Auth changes.
- Scheduled deletion and revenue failure-injection tests pass.
- Revenue backlog and `needsAttention` audit counts remain zero in production logs.

The portal intentionally does not expose permanent deletion or subscription overrides.
