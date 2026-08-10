const assert = require("node:assert/strict");
const test = require("node:test");
const {
	revenueEventData,
	revenueEventId,
	revenueFailureState,
	revenueRetryDelayMillis,
} = require("../lib/revenueOutbox");

const input = {
	provider: "razorpay",
	providerTransactionId: "payment/with/slash",
	userId: "user-1",
	amountMicros: 2_990_000,
	currency: "USD",
	kind: "charge",
	environment: "production",
	occurredAt: new Date("2026-08-08T00:00:00Z"),
};

test("revenue outbox IDs are deterministic and safe Firestore document IDs", () => {
	const id = revenueEventId(input);
	assert.match(id, /^[0-9a-f]{64}$/);
	assert.equal(id, revenueEventId({ ...input }));
	assert.notEqual(id, revenueEventId({ ...input, providerTransactionId: "other" }));
});

test("revenue events begin pending with normalized timestamps", () => {
	const data = revenueEventData(input);
	assert.equal(data.status, "pending");
	assert.equal(data.attempts, 0);
	assert.equal(data.input.occurredAt.toDate().toISOString(), input.occurredAt.toISOString());
});

test("revenue retries use capped exponential backoff", () => {
	assert.equal(revenueRetryDelayMillis(1), 30_000);
	assert.equal(revenueRetryDelayMillis(2), 60_000);
	assert.equal(revenueRetryDelayMillis(100), 6 * 60 * 60 * 1000);
});

test("the tenth failed attempt becomes a visible dead letter", () => {
	assert.deepEqual(revenueFailureState(9, 1_000), {
		status: "failed",
		nextAttemptAtMillis: 1_000 + revenueRetryDelayMillis(9),
	});
	assert.deepEqual(revenueFailureState(10, 1_000), {
		status: "dead_letter",
		nextAttemptAtMillis: null,
	});
});
