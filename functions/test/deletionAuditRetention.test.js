const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
	DELETION_AUDIT_RETENTION_MS,
	isDeletionAuditExpired,
	deleteExpiredDeletionAudit,
} = require("../lib/deletionAuditRetention");

const now = Timestamp.fromMillis(Date.parse("2026-11-24T12:00:00Z"));
const cutoff = Timestamp.fromMillis(now.toMillis() - DELETION_AUDIT_RETENTION_MS);

test("both terminal states expire at 90 days, never before their own terminal timestamp", () => {
	for (const state of ["completed", "cancelled"]) {
		const field = `${state}At`;
		const data = { state, retentionHold: false, [field]: cutoff };
		assert.equal(isDeletionAuditExpired(data, state, now), true);
		assert.equal(isDeletionAuditExpired({ ...data, [field]: Timestamp.fromMillis(cutoff.toMillis() + 1) }, state, now), false);
		for (const invalid of [undefined, null, cutoff.toDate().toISOString(), now]) {
			assert.equal(isDeletionAuditExpired({ ...data, [field]: invalid }, state, now), false);
		}
	}
});

test("active states, incident holds and pre-policy records fail closed", () => {
	const data = { state: "completed", retentionHold: false, completedAt: cutoff };
	for (const retentionHold of [true, undefined, null, 0, "false"]) {
		assert.equal(isDeletionAuditExpired({ ...data, retentionHold }, "completed", now), false);
	}
	for (const state of ["pending", "deleting", "revoking", "cancelled", undefined]) {
		assert.equal(isDeletionAuditExpired({ ...data, state }, "completed", now), false);
	}
	assert.equal(isDeletionAuditExpired(undefined, "completed", now), false);
});

test("cleanup re-reads the audit and user in a transaction before removing only the audit", async () => {
	const ref = { id: "request-id" };
	const userRef = {};
	const initial = { uid: "user-id", state: "completed", completedAt: cutoff, retentionHold: false };
	for (const [audit, user, expected] of [
		[initial, undefined, true],
		[initial, { scheduledDeletion: { requestId: "another-request" } }, true],
		[initial, { scheduledDeletion: { requestId: ref.id } }, false],
		[{ ...initial, retentionHold: true }, undefined, false],
		[{ ...initial, state: "deleting" }, undefined, false],
		[{ ...initial, completedAt: now }, undefined, false],
		[{ ...initial, uid: "different-user" }, undefined, false],
		[undefined, undefined, false],
	]) {
		const reads = [], deletes = [];
		const db = {
			collection: () => ({ doc: () => userRef }),
			runTransaction: async (callback) => callback({
				get: async (target) => { reads.push(target); return { data: () => target === ref ? audit : user }; },
				delete: (target) => deletes.push(target),
			}),
		};
		assert.equal(await deleteExpiredDeletionAudit(db, ref, "user-id", "completed", now), expected);
		assert.deepEqual(reads, [userRef, ref]);
		assert.deepEqual(deletes, expected ? [ref] : []);
	}
});

test("malformed account references never access a document path", async () => {
	for (const uid of [null, undefined, "", "users/someone", 123]) {
		assert.equal(await deleteExpiredDeletionAudit({}, { id: "request-id" }, uid, "completed", now), false);
	}
});
