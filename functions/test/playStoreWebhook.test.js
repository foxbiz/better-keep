const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
	executeClaimedPlayEvent,
	playEventClaimOutcome,
	safePlayEventLogData,
} = require("../lib/exports/playStoreWebhook");
const { revenueEventId } = require("../lib/revenueOutbox");

const unused = async () => {
	throw new Error("Unexpected operation");
};

test("Google Play notification logs redact purchase tokens", () => {
	const data = safePlayEventLogData({
		packageName: "io.foxbiz.better_keep",
		subscriptionNotification: { notificationType: 2, purchaseToken: "secret" },
	});
	assert.equal(data.notificationType, 2);
	assert.doesNotMatch(JSON.stringify(data), /secret/);
	assert.equal("purchaseToken" in data, false);
});

test("Google Play notifications use a retrying Pub/Sub consumer, not a public webhook", () => {
	const source = readFileSync("src/exports/playStoreWebhook.ts", "utf8");
	const index = readFileSync("src/index.ts", "utf8");
	assert.match(source, /onMessagePublished/);
	assert.match(source, /topic: "play-store-notifications"/);
	assert.match(source, /retry: true/);
	assert.doesNotMatch(source, /onRequest/);
	assert.match(index, /processPlayStoreNotification/);
	assert.doesNotMatch(index, /import playStoreWebhook|\tplayStoreWebhook,/);
});

test("a succeeded duplicate performs no work and is acknowledged", async () => {
	let processed = 0;
	const result = await executeClaimedPlayEvent({
		claim: async () => "succeeded",
		complete: unused,
		fail: unused,
		process: async () => {
			processed += 1;
		},
	});
	assert.equal(result, "duplicate");
	assert.equal(processed, 0);
});

test("a concurrent duplicate with an active lease fails for retry", async () => {
	let processed = 0;
	await assert.rejects(
		executeClaimedPlayEvent({
			claim: async () => "busy",
			complete: unused,
			fail: unused,
			process: async () => {
				processed += 1;
			},
		}),
		(error) => {
			assert.equal(error.code, "play-event-busy");
			assert.doesNotMatch(error.message, /purchase|token|GPA\./i);
			return true;
		},
	);
	assert.equal(processed, 0);
});

test("failed records and expired leases are immediately reclaimable", () => {
	const now = Date.parse("2026-08-09T00:00:00.000Z");
	assert.equal(playEventClaimOutcome({ status: "failed" }, now), "claimed");
	assert.equal(
		playEventClaimOutcome(
			{
				status: "processing",
				leaseUntil: Timestamp.fromMillis(now - 1),
			},
			now,
		),
		"claimed",
	);
	assert.equal(
		playEventClaimOutcome(
			{
				status: "processing",
				leaseUntil: Timestamp.fromMillis(now + 1),
			},
			now,
		),
		"busy",
	);
	assert.equal(playEventClaimOutcome({ status: "succeeded" }, now), "succeeded");
});

test("a crash after a ledger mutation retries without duplicate revenue", async () => {
	const now = Date.parse("2026-08-09T00:00:00.000Z");
	const ledger = new Set();
	let state = {};
	let completionAttempts = 0;
	const run = () =>
		executeClaimedPlayEvent({
			claim: async () => {
				const outcome = playEventClaimOutcome(state, now);
				if (outcome === "claimed") {
					state = {
						status: "processing",
						leaseUntil: Timestamp.fromMillis(now + 60_000),
					};
				}
				return outcome;
			},
			process: async () => {
				ledger.add(
					revenueEventId({
						provider: "play_store",
						providerTransactionId: "GPA.redacted:charge",
					}),
				);
			},
			complete: async () => {
				completionAttempts += 1;
				if (completionAttempts === 1) throw new Error("simulated crash");
				state = { status: "succeeded" };
			},
			fail: async () => {
				state = { status: "failed", leaseUntil: null };
			},
		});

	await assert.rejects(run(), /simulated crash/);
	assert.equal(state.status, "failed");
	assert.equal(await run(), "processed");
	assert.equal(state.status, "succeeded");
	assert.equal(ledger.size, 1);
});
