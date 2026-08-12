const assert = require("node:assert/strict");
const test = require("node:test");
const { isUuid, runAuditedMutation, sameAdminAction } = require("../lib/adminAudit");
const { revokedAfter } = require("../lib/exports/reconcileAdminActions");
const { Timestamp } = require("firebase-admin/firestore");

test("admin action request IDs are strict UUIDs", () => {
	assert.equal(isUuid("c93d6883-b20e-4e73-a513-d81f17a04d83"), true);
	assert.equal(isUuid("not-an-id"), false);
});

test("idempotency identity includes admin, target, and action", () => {
	const identity = { adminUid: "admin", targetUid: "user", action: "user.disabled" };
	assert.equal(sameAdminAction(identity, identity), true);
	assert.equal(sameAdminAction({ ...identity, targetUid: "other" }, identity), false);
	assert.equal(sameAdminAction({ ...identity, action: "user.enabled" }, identity), false);
});

test("session reconciliation compares revocation time with request time", () => {
	const requestedAt = Timestamp.fromMillis(Date.parse("2026-08-08T10:00:00Z"));
	assert.equal(revokedAfter("Sat, 08 Aug 2026 10:00:00 GMT", requestedAt), true);
	assert.equal(revokedAfter("Sat, 08 Aug 2026 09:59:00 GMT", requestedAt), false);
});

test("an Auth failure becomes a terminal failed audit without index changes", async () => {
	const calls = [];
	await assert.rejects(() => runAuditedMutation({
		start: async () => ({ execute: true }),
		performAuthMutation: async () => { calls.push("auth"); throw new Error("auth failed"); },
		synchronizeIndex: async () => calls.push("index"),
		markSucceeded: async () => calls.push("succeeded"),
		markFailed: async () => calls.push("failed"),
		markPendingError: async () => calls.push("pending"),
	}));
	assert.deepEqual(calls, ["auth", "failed"]);
});

test("a failure after Auth mutation leaves the durable audit pending for reconciliation", async () => {
	const calls = [];
	await assert.rejects(() => runAuditedMutation({
		start: async () => ({ execute: true }),
		performAuthMutation: async (markStarted) => {
			calls.push("auth");
			markStarted();
			return { success: true };
		},
		synchronizeIndex: async () => { calls.push("index"); throw new Error("index failed"); },
		markSucceeded: async () => calls.push("succeeded"),
		markFailed: async () => calls.push("failed"),
		markPendingError: async () => calls.push("pending"),
	}));
	assert.deepEqual(calls, ["auth", "index", "pending"]);
});

test("a completed duplicate returns its stored result without mutation", async () => {
	const result = await runAuditedMutation({
		start: async () => ({ execute: false, result: { success: true } }),
		performAuthMutation: async () => { throw new Error("must not execute"); },
		synchronizeIndex: async () => undefined,
		markSucceeded: async () => undefined,
		markFailed: async () => undefined,
		markPendingError: async () => undefined,
	});
	assert.deepEqual(result, { success: true });
});
