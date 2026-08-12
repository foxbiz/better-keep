const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const { matchesAdminUserSegment, providerSubscriptionCounts } = require("../lib/adminApi");

test("search segment predicates are applied before returning results", () => {
	const paid = { subscriptionClass: "paid", renewalState: "renewing", disabled: false };
	const cancelled = { ...paid, renewalState: "cancelled" };
	const disabled = { subscriptionClass: "free", renewalState: "none", disabled: true };
	assert.equal(matchesAdminUserSegment(paid, "paid"), true);
	assert.equal(matchesAdminUserSegment(paid, "cancelled"), false);
	assert.equal(matchesAdminUserSegment(cancelled, "cancelled"), true);
	assert.equal(matchesAdminUserSegment(disabled, "disabled"), true);
	assert.equal(matchesAdminUserSegment(disabled, "paid"), false);
});

test("provider totals explain overlaps without inflating unique paid users", () => {
	const future = Timestamp.fromMillis(Date.now() + 86400000);
	const counts = providerSubscriptionCounts([
		{ source: "play_store", plan: "pro", environment: "production", expiresAt: future, subscriptionState: "SUBSCRIPTION_STATE_CANCELED", willAutoRenew: false },
		{ source: "razorpay", plan: "pro", environment: "production", expiresAt: future, subscriptionState: "ACTIVE", willAutoRenew: true },
	]);
	assert.equal(counts.play_store.entitled, 1);
	assert.equal(counts.play_store.cancelledWithAccess, 1);
	assert.equal(counts.razorpay.renewing, 1);
});
