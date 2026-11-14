# Account deletion operations

This describes the local hardening changes. It does not authorize production deployment,
queries, data edits, scheduler changes, or execution of cleanup jobs.

## Lifecycle and safeguards

1. While `ACCOUNT_DELETION_ENABLED=true`, an authenticated owner requests an emailed OTP.
   When paused, both OTP issuance and scheduling return `unavailable` with reason
   `account-deletion-paused`; the client shows a support message. Repeated requests within 60 seconds
   return cooldown details without replacing the original code. The client permits entering
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
4. Reminders are suppressed while deletion is paused. They require a matching backend proof and a future deadline, and use an explicit
   UTC date/time. Successful sends are marked conditionally. SMTP cannot participate in a
   Firestore transaction: a cancellation during sending can still produce a stale email,
   and an ambiguous SMTP response can cause a retry duplicate. Neither can recreate a
   deletion request. Delivery failures fail the scheduled invocation for retry/monitoring.
5. After the grace period, an enabled worker transactionally claims a verified request as
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
The trigger continues securing accepted requests even when `ACCOUNT_DELETION_ENABLED` is
off; that switch prevents new requests and destructive cleanup, not completion of an
accepted session-safety step.

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
ID fails closed. No recovery command was run against development or production records
during local validation.

## Emergency stop and partial-deletion recovery

- Keep Cloud Scheduler paused and `ACCOUNT_DELETION_ENABLED` unset/false during the incident
  and rollout. The switch stops **all new invocations**, including partial retries. It does
  not interrupt code already running with a previously loaded configuration. Pausing Scheduler
  also does not cancel an in-flight invocation; verify it has stopped before recovery edits.
- A `deleting` account is deliberately quarantined, not permanently unrecoverable. Do not
  reset it to `pending`, clear its marker, force `completed`, or send an account-restored
  email merely because the lease expired. Some data might already be gone.
- With explicit permission for production inspection, identify the exact UID/request ID and
  compare root schedule, audit proof, lease, Auth state, logs, and remaining data. Preserve
  incident evidence; never copy tokens, OTPs, email addresses or note contents into reports.
- If the request was legitimate and the user still wants deletion, repair the failed dependency,
  validate the matching proof, and obtain approval for resuming deletion. Enable the worker and
  resume the scheduler only when **all eligible requests** are cleared for processing; this is
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

Audit records currently have **no automatic retention deletion**. This is an explicit incident
hold, not a claim of complete erasure of operational metadata. They contain UID and lifecycle
metadata, not note content, OTPs or tokens. Before enabling deletion, approve and implement a
retention policy for terminal records (and any billing/operational records outside this flow).
Do not prune pending/deleting proofs or incident evidence with an indiscriminate TTL.

## Proposed retention policy (not enabled)

Owner approval and implementation are required before enabling account deletion:

- Keep terminal `completed` and `cancelled` audit records for **90 days** after their terminal
  timestamp for support and incident investigation. Store only request ID, UID, lifecycle
  timestamps, state and notification markers; never notes, tokens, OTPs or email addresses.
- Delete terminal records after 90 days only when no incident/dispute hold applies. A cleanup
  job must transactionally recheck terminal state, deadline and explicit hold before deletion.
  Use neither a blanket TTL nor a TTL on pending/deleting records.
- Retain pending/deleting and incident-held records until the workflow or investigation is
  resolved. Review held records monthly under an approved, read-only inventory procedure.
- Retain only aggregate, non-identifying deletion counters after audit removal. Define log,
  backup and billing retention separately; audit removal alone does not erase those copies.
- Before rollout, test retention boundaries, concurrent state changes and hold enforcement
  using disposable staging records, then obtain approval to activate the policy.

This is a proposed operational window, not a legal retention determination. No TTL, cleanup
job, production query or data deletion has been enabled by this change.

## Rollout and verification

1. Keep the deletion scheduler paused. Obtain deployment permission.
2. Deploy protected-field Firestore rules **first**, then backend functions with deletion disabled.
   Older clients lose their direct-write cancellation fallback; server cancellation remains supported.
3. Verify disabled-worker logs and deployed rules. Release the client changes through the normal
   app release process. Do not infer live provider/SMTP behavior from emulator results.
4. Run `npm --prefix functions run test:deletion` for isolated synthetic Auth/Firestore/Storage
   regression tests (requires Bash, including Git Bash/WSL on Windows). This suite is included in `npm test release` and therefore `npm run release`
   and the release CI workflow. Run focused Flutter auth tests and the full rules suite as well.
5. In staging, verify native/custom-provider sign-in, OTP cooldown after timeout, cancellation,
   token expiry and resumable-upload behavior, reminder delivery, partial failure/retry, and support
   messaging. Confirm backups/recovery procedures and audit retention before enabling production.
6. Obtain explicit approval before enabling deletion or resuming Scheduler. Monitor the worker's
   processed/succeeded/failed/held/waitingForTokens counters and reminder failures. Cloud log metrics
   and alerts require separate production configuration; adding log output does not create alerts.

## Read-only checks awaiting an approved environment

The deletion query uses the ascending `scheduledDeletion.deleteAt` single-field index with
its ascending document-name suffix. There is no exemption for this field in the repository;
[Firebase documents this default ordering](https://firebase.google.com/docs/firestore/query-data/index-overview#default_ordering_and_the_name_field).
Inspect deployed exemptions and run the exact paged query in staging with permission before
enabling the worker. Emulator success alone does not establish deployed index availability.

For an approved held-request inventory, use a read-only report with a pseudonymous account
reference, request ID, state, schedule/deadline, proof validity, last-sign-in comparison,
lease status and hold reason. Exclude email, note content, OTPs and tokens. Decide each
legacy/unproven request individually; do not backfill authorization proof or use TTL to
clear disputed schedules. No inventory query or mutation was performed by this follow-up.

An account-scoped recovery command needs separate design/review of backup restoration,
request identity and lease checks before it can safely replace the manual recovery plan.
The current worker cannot target one account. This remains an explicit operational gap;
never resume the global worker merely to recover one disputed account.


## Release gates

- Verify the revocation and cancellation-notification triggers exist with retries enabled.
- Verify both the environment switch and Scheduler state; an enabled switch cannot detect a paused job.
- Inventory legacy/unproven schedules with permission and resolve their retention/consent separately.
- Test real ID-token expiry, resumable uploads and interrupted deletion in a disposable staging account.
- Approve and implement the proposed retention policy before enabling cleanup; the proposal alone is not a purge job.
