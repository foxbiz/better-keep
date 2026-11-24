# Account deletion operations

Lifecycle, audit retention, and recovery procedures for account deletion.

## Lifecycle and safeguards

1. An authenticated owner requests an emailed OTP; no environment enable flag is required.
   Repeated requests within 60 seconds return cooldown details without replacing the original code. The client permits entering
   that code after a cancelled or timed-out email request.
2. `scheduleDeletion` atomically consumes the OTP, creates a 30-day schedule in
   `revoking` state and an audit record with matching owner, dates and verification.
   Client rules prohibit writing deletion fields or the audit record. Device records,
   E2EE keys and notes remain intact. The same commit writes `tokensRevokedAt`.
   `revokeScheduledDeletionSessions` observes the durable request, claims a ten-minute
   attempt lease, revokes Auth refresh tokens, then atomically transitions both records
   to `pending`. Sign-in/cancellation return retryable `unavailable` during `revoking`;
   no deletion worker can claim it. This prevents a delayed revocation from invalidating
   a newly issued sign-in. Existing ID tokens can still live for an hour, so this is not
   a promise of immediate logout on every device.
   The obsolete `verifyDeletionOtp` endpoint rejects without modifying the code; clients
   must submit it directly to `scheduleAccountDeletion` for atomic verification.
3. Fresh native sign-in and custom-token/OAuth completion paths call `cancelDeletion`.
   Existing-session startup also attempts cancellation when it finds a schedule. Ordinary
   sign-ins read user and OTP documents transactionally without writing when neither needs
   cancellation. Existing sessions/token refreshes alone are not a cancellation guarantee;
   the worker additionally holds requests with missing or newer Auth sign-in metadata.
   Keep cancellation before sign-in/token issuance completes. Moving it to a later client
   step creates a window in which authentication can succeed but the worker can still claim
   pending deletion; its Auth metadata snapshot is read outside the Firestore transaction.
4. Reminders have a separate Scheduler job; pause it separately during incidents.
   They require a matching backend proof and a future deadline, and use an explicit
   UTC date/time. Successful sends are marked conditionally. SMTP cannot participate in a
   Firestore transaction: a cancellation during sending can still produce a stale email,
   and an ambiguous SMTP response can cause a retry duplicate. Neither can recreate a
   deletion request. Delivery failures fail the scheduled invocation for retry/monitoring.
5. After the grace period, the worker transactionally claims a verified request as
   `deleting`. Cancellation then fails with an actionable support message. The worker disables
   the Auth user and revokes refresh tokens, records `authInvalidatedAt`, and waits at least
   **65 minutes** before any purge. A later daily invocation resumes after this wait; the
   displayed deadline means eligibility, not an exact deletion execution time.
6. The purge removes OAuth sessions, user/admin subcollections, owned `shares` documents
   and their descendants (rules prevent new requests under deleted shares), both `users/{uid}/` and `shares/{uid}/` Storage prefixes, then Auth
   and the Firestore roots. It marks the audit record `completed` only after all steps succeed.
   Partial failures retain the non-cancellable claim. Leases are renewed/checked between
   stages and individual Storage/shared-document operations. Lost leases fail closed.

The token wait addresses writes authenticated with still-valid ID tokens: Firebase documents
[a one-hour ID-token lifetime](https://firebase.google.com/docs/auth/admin/manage-sessions).
Disabling Auth prevents new normal sign-in/refresh issuance. Re-enabling the Auth record
before a retry restarts the wait. Storage rules can consult only the default Firestore
database, whereas production uses `better-keep`; see
[Storage rule limitations](https://firebase.google.com/docs/storage/security/rules-conditions#enhance_with_cloud_firestore).
Pre-authorized resumable uploads and already-running backend operations still need live
staging validation; emulator success is not proof of their production timing behavior.

The worker runs with one instance/concurrent request, scans pages of 100, and claims at most
25 requests per invocation within a 480-second scan budget (540-second function timeout).
Its backend-only `accountDeletionWorker/scan` cursor persists between runs so held requests
cannot monopolize the first page. At scan completion the cursor resets; a request inserted
before the cursor is considered on the next full pass. A single very large account can still
hit the function timeout; large collections may need multiple runs. The saved cursor can
advance past the failed account, and its active lease can hold an immediate retry; a later
scan repeats idempotent stages with the retained claim. Budget exhaustion remains a failure
signal, not an implicit declaration that deletion finished.

Owner reads of named note/label/order/settings paths remain available without a deletion-state
lookup. Writes retain the deletion guard. Generic subtree paths still use the guard for both
reads and writes. Do not claim an exact billing delta without measuring representative requests.

## Session revocation operations

Deploy `revokeScheduledDeletionSessions` with the scheduling callable **before enabling
new deletion requests**. Event retries are enabled. A ten-minute lease protects only the
pre-dispatch claim. A second transaction fences the attempt before calling Auth; that
fence cannot be stolen on timeout. [Cloud Run timeout does not terminate the instance](https://docs.cloud.google.com/run/docs/configuring/request-timeout),
so it is not proof that the invocation stopped. The trigger has a 300-second timeout to
allow more time for Auth and Firestore; this is a budget, not a recovery guarantee.
If Auth settles and the final completion transaction fails, a conditional compensation
transaction releases only that same still-revoking attempt for event retry. A lost commit
acknowledgement cannot alter a completed/cancelled request or a replacement attempt.
Cancellation stays blocked until Auth succeeds and the matching completion commits.
Duplicate events after completion/cancellation do nothing. A missing Auth user can finish
this phase.

A process crash during dispatch, or failure of both completion and compensation writes,
leaves the request fenced. Monitor failed trigger executions and `revoking` requests older
than ten minutes. Restore the dependency first. Expiry alone never authorizes takeover.
The trigger continues securing accepted requests even when the deletion scheduler is paused;
pausing a scheduled worker does not stop this accepted session-safety step.

### Account-scoped recovery

Use this only with separately authorized inspection and recovery of the named account.
First establish from execution/incident evidence that the original invocation has stopped
and cannot resume its Auth call. A timeout, expired lease or Auth revocation timestamp is
**not** sufficient evidence. If termination cannot be established, keep the fence and
escalate the incident. Never use this command to bypass that prerequisite.

Build the current Functions code, then perform a read-only check with explicit identifiers
from the matching user/audit records (there is no default project or database):

```sh
npm --prefix functions run build
node functions/scripts/recoverDeletionSessions.mjs \
  --project=PROJECT_ID --database=DATABASE_ID --uid=USER_ID \
  --request-id=REQUEST_UUID --attempt=ATTEMPT_UUID
```

After confirming the invocation stopped and obtaining mutation approval, repeat the same
command with `--execute --confirm-invocation-stopped`. It refuses a mismatched owner,
request, proof, attempt or active lease. It conditionally releases the stranded dispatch,
records recovery metadata, then performs a new Auth revocation and completion through the
normal lifecycle. It never directly enables sign-in or deletes notes. This also works when
the original event's retry retention has expired. Emulator execution requires both Auth
and Firestore on loopback with an explicit `demo-*` project, preventing mixed targets.

If another retry claims the released attempt, the command may report in-progress; inspect
that invocation rather than resetting it. If the recovery command itself crashes after
dispatch, repeat the incident checks against its **new** attempt ID. Reusing a stale attempt
ID fails closed.

## Emergency stop and partial-deletion recovery

- Pause the deletion, reminder, and audit-cleanup Cloud Scheduler jobs during an incident.
  There is no environment kill switch. Pausing Scheduler does not stop in-flight functions,
  direct invocations, or new callable OTP/scheduling requests. Verify running work has stopped
  before recovery edits; stopping callable requests requires a separately approved backend change.
- A `deleting` account is deliberately quarantined, not permanently unrecoverable. Do not
  reset it to `pending`, clear its marker, force `completed`, or send an account-restored
  email merely because the lease expired. Some data might already be gone.
- With explicit permission for production inspection, identify the exact UID/request ID and
  compare root schedule, audit proof, lease, Auth state, logs, and remaining data. Preserve
  incident evidence; never copy tokens, OTPs, email addresses or note contents into reports.
- If the request was legitimate and the user still wants deletion, repair the failed dependency,
  validate the matching proof, and obtain approval for resuming deletion. Resume the scheduler
  only when **all eligible requests** are cleared for processing; this is
  a global worker, not a single-account recovery command. Existing claims resume after leases
  expire and token waiting periods pass. Verify the final audit state and cleanup inventory.
- If the request is disputed, retain the stop. Determine whether any purge ran. Restore missing
  data from a verified backup/local copy as needed, reconcile root/audit/Auth state under a
  separately reviewed, account-scoped recovery plan, and only then re-enable sign-in. There is
  intentionally no generic "undo deletion" operation. If recovery evidence is absent, say so.
- Legacy/unproven schedules and missing-Auth pending requests are held and counted in logs.
  Never fabricate proof, shorten the grace period, or automatically convert these into v2 requests.

Sign-in cancellation remains fail-closed if Firestore is unavailable. The worker reads Auth
sign-in metadata outside its claim transaction; that snapshot can be stale, so allowing a
sign-in without transactional cancellation is not a safe fallback. The blocking hook returns
an actionable retryable `unavailable` error. During an outage, restore Firestore access and
retry sign-in; do not bypass the check, clear claims, or enable the worker to recover access.

Cancellation notifications now follow the backend audit transition through
`sendDeletionCancellation`, including cancellations performed by sign-in hooks. This trigger
continues while deletion is paused. It does not delay sign-in, and a delivery marker suppresses
completed event retries. Missing users/email addresses receive a terminal skipped marker.
SMTP success followed by a process failure can still duplicate a
notice. Legacy schedules without an audit record cannot produce this notification; cancellation
still succeeds. Deploy the new trigger with the callable changes to avoid a notification gap.

## Audit retention

`cleanupDeletionAuditRecords` runs daily at 04:00 UTC without an environment flag. It removes
`completed` and `cancelled` audit records at least **90 days** after their terminal timestamp,
only when `retentionHold` is explicitly `false`. Each deletion transaction rechecks the state,
timestamp, hold, UID, and whether the user still references the request. It never deletes accounts.

New audit records have `retentionHold: false`. Missing or malformed hold values preserve older
records; there is no automatic backfill. Active and held audits remain until separately reviewed.
An audit retention hold does not pause account deletion. The 90-day window is operational,
not a legal retention determination; billing, logs, and backups have separate retention policies.

Two composite indexes support the cleanup queries: `state`, `retentionHold`, and either
`completedAt` or `cancelledAt`. The job scans up to five 100-record pages per state. Checkpoints
under `accountDeletionWorker/auditRetention_{state}` let later runs continue past skipped
records, then wrap to revisit them. Logs contain aggregate scanned/deleted/skipped counts;
persistent skips need operator review. After 480 seconds it stops starting new work and saves
partial-page progress; logs flag budget exhaustion. In-flight operations may outlast that budget.

## Deployment and validation

- Deploy protected-field rules and the retention indexes first. Confirm both indexes are `READY`
  before deploying cleanup; deployment activates the job without a flag.
- Deploy the revocation and cancellation-notification triggers with the callables, and verify
  retries and Scheduler state. Deletion, reminders, and audit cleanup have separate jobs.
- Run `npm --prefix functions run test:deletion` for isolated Auth/Firestore/Storage regression
  tests. The suite also runs in release CI. Run focused Flutter auth tests and the full rules suite.
- Validate sign-in/cancellation, OTP cooldown, real token expiry and resumable uploads, reminder
  delivery, and interrupted deletion in a disposable staging account. Emulator results do not
  establish live provider/SMTP behavior or deployed index readiness.
- Verify recovery procedures and monitor deletion and reminder failures. The worker is global;
  do not resume it merely to recover one disputed account.
