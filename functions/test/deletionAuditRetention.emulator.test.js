const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");
const { test, after, afterEach } = require("node:test");
assert.match(process.env.FIRESTORE_EMULATOR_HOST || "", /^(127\.0\.0\.1|localhost):\d+$/);
process.env.GCLOUD_PROJECT = "demo-better-keep-deletion";
process.env.FUNCTIONS_EMULATOR = "true";
const { Timestamp } = require("firebase-admin/firestore");
const { db, app } = require("../lib/config");
const {
	DELETION_AUDIT_RETENTION_MS,
	deleteExpiredDeletionAudit,
	cleanupDeletionAudits,
} = require("../lib/deletionAuditRetention");
const handler = require("../lib/exports/cleanupDeletionAuditRecords").default;
const now = Timestamp.fromMillis(Date.parse("2026-11-24T12:00:00Z"));
const cutoff = Timestamp.fromMillis(now.toMillis() - DELETION_AUDIT_RETENTION_MS);
const created = [];

async function fixture(overrides = {}, scheduled = false) {
	const uid = `retention-${randomUUID()}`;
	const ref = db.collection("accountDeletionRequests").doc(randomUUID());
	const user = db.collection("users").doc(uid);
	await user.set(scheduled ? { scheduledDeletion: { requestId: ref.id, state: "deleting" } } : { synthetic: true });
	await ref.set({ uid, state: "completed", completedAt: cutoff, retentionHold: false, ...overrides });
	created.push(ref, user);
	return { ref, user, uid };
}
afterEach(async () => {
	await Promise.all(created.splice(0).map((ref) => ref.delete()));
	await Promise.all(["completed", "cancelled"].map((state) =>
		db.collection("accountDeletionWorker").doc(`auditRetention_${state}`).delete()));
});
after(() => app.delete());

test("cleanup paginates past 100 records and preserves held, recent, active and linked records", async () => {
	const eligible = [];
	for (let i = 0; i < 105; i++) eligible.push(await fixture());
	eligible.push(await fixture({ state: "cancelled", cancelledAt: cutoff }));
	const protectedRecords = [
		await fixture({ retentionHold: true }),
		await fixture({ retentionHold: null }),
		await fixture({ completedAt: Timestamp.fromMillis(cutoff.toMillis() + 1) }),
		await fixture({ state: "pending" }),
		await fixture({ state: "revoking" }),
		await fixture({ state: "deleting" }),
		await fixture({}, true),
	];
	const legacy = await fixture();
	const { FieldValue } = require("firebase-admin/firestore");
	await legacy.ref.update({ retentionHold: FieldValue.delete() });
	protectedRecords.push(legacy);
	const result = await cleanupDeletionAudits(db, now);
	assert.equal(result.deleted, eligible.length);
	for (const { ref, user } of eligible) {
		assert.equal((await ref.get()).exists, false);
		assert.equal((await user.get()).exists, true);
	}
	for (const { ref } of protectedRecords) assert.equal((await ref.get()).exists, true);
	assert.equal((await cleanupDeletionAudits(db, now)).deleted, 0);
});

test("a hold or state change committed after candidate selection blocks cleanup", async () => {
	for (const update of [{ retentionHold: true }, { state: "deleting" }, { completedAt: now }]) {
		const { ref, uid } = await fixture();
		const candidate = await ref.get();
		await ref.update(update);
		assert.equal(await deleteExpiredDeletionAudit(db, candidate.ref, uid, "completed", now), false);
		assert.equal((await ref.get()).exists, true);
	}
});

test("a time-limited partial page resumes without losing remaining candidates", async () => {
	const first = await fixture({ completedAt: Timestamp.fromMillis(cutoff.toMillis() - 1) });
	const remaining = await fixture();
	const cancelled = await fixture({ state: "cancelled", cancelledAt: cutoff });
	let elapsed = 0;
	const slowDb = {
		collection: db.collection.bind(db),
		runTransaction: async (...args) => {
			const result = await db.runTransaction(...args);
			elapsed = 480_000;
			return result;
		},
	};
	const result = await cleanupDeletionAudits(slowDb, now, () => elapsed);
	assert.equal(result.timeBudgetExhausted, true);
	assert.equal(result.deleted, 1);
	const checkpoint = db.collection("accountDeletionWorker").doc("auditRetention_completed");
	assert.equal((await checkpoint.get()).data().requestId, first.ref.id);
	assert.equal((await first.ref.get()).exists, false);
	assert.equal((await remaining.ref.get()).exists, true);
	assert.equal((await cancelled.ref.get()).exists, true);

	const resumed = await cleanupDeletionAudits(db, now);
	assert.equal(resumed.timeBudgetExhausted, false);
	assert.equal(resumed.deleted, 2);
	assert.equal((await checkpoint.get()).exists, false);
	assert.equal((await remaining.ref.get()).exists, false);
	assert.equal((await cancelled.ref.get()).exists, false);
});

test("the scheduled cleanup runs by default and preserves held audits and user data", async () => {
	const completedAt = Timestamp.fromMillis(Date.now() - DELETION_AUDIT_RETENTION_MS - 1000);
	const eligible = await fixture({ completedAt });
	const held = await fixture({ completedAt, retentionHold: true });
	await handler.run({ scheduleTime: new Date().toISOString() });
	assert.equal((await eligible.ref.get()).exists, false);
	assert.equal((await eligible.user.get()).exists, true);
	assert.equal((await held.ref.get()).exists, true);
});

test("scan progress survives the page cap and wraps to revisit previously skipped records", async () => {
	const old = Timestamp.fromMillis(cutoff.toMillis() - 1000);
	const batch = db.batch();
	const skipped = [];
	for (let i = 0; i < 500; i++) {
		const ref = db.collection("accountDeletionRequests").doc(randomUUID());
		batch.set(ref, { uid: null, state: "completed", completedAt: old, retentionHold: false });
		skipped.push(ref);
		created.push(ref);
	}
	await batch.commit();
	const eligible = await fixture({ completedAt: Timestamp.fromMillis(cutoff.toMillis() - 1) });
	const checkpoint = db.collection("accountDeletionWorker").doc("auditRetention_completed");

	const first = await cleanupDeletionAudits(db, now);
	assert.equal(first.scanned, 500);
	assert.equal(first.skipped, 500);
	assert.equal((await eligible.ref.get()).exists, true);
	assert.equal((await checkpoint.get()).exists, true);

	const second = await cleanupDeletionAudits(db, now);
	assert.equal(second.deleted, 1);
	assert.equal((await eligible.ref.get()).exists, false);
	assert.equal((await checkpoint.get()).exists, false);
	for (const ref of skipped) assert.equal((await ref.get()).exists, true);

	// A reviewed repair behind the saved cursor is revisited after wraparound.
	await skipped[0].update({ uid: eligible.uid });
	await cleanupDeletionAudits(db, now);
	assert.equal((await skipped[0].get()).exists, false);
	assert.equal((await eligible.user.get()).exists, true);
});
