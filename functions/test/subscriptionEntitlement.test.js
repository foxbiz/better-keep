const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
	ENTITLEMENT_CONTRACT_VERSION,
	evaluateSubscription,
	verifiedEntitlementPayload,
} = require("../lib/subscriptionEntitlement");

const now = Date.parse("2026-08-08T00:00:00.000Z");
const future = Timestamp.fromMillis(now + 86400000);
const past = Timestamp.fromMillis(now - 1);

function play(state, expiresAt = future, willAutoRenew = false) {
	return evaluateSubscription({
		plan: "pro",
		source: "play_store",
		environment: "production",
		subscriptionState: state,
		expiresAt,
		willAutoRenew,
	}, now);
}

test("Google Play active, grace, and cancelled-future states remain entitled", () => {
	assert.equal(play("SUBSCRIPTION_STATE_ACTIVE", future, true).productionPaid, true);
	assert.equal(play("SUBSCRIPTION_STATE_IN_GRACE_PERIOD").entitlementState, "grace");
	assert.equal(play("SUBSCRIPTION_STATE_CANCELED").entitlementState, "cancelled_access");
	assert.equal(play("SUBSCRIPTION_STATE_CANCELED").entitled, true);
});

test("hold, pause, pending, revoked, and expired states do not grant access", () => {
	for (const state of [
		"SUBSCRIPTION_STATE_ON_HOLD",
		"SUBSCRIPTION_STATE_PAUSED",
		"SUBSCRIPTION_STATE_PENDING",
		"SUBSCRIPTION_STATE_REVOKED",
		"SUBSCRIPTION_STATE_EXPIRED",
	]) assert.equal(play(state).entitled, false, state);
	assert.equal(play("SUBSCRIPTION_STATE_ACTIVE", past, true).entitled, false);
});

test("test purchases and non-provider access are excluded from paid users", () => {
	assert.equal(evaluateSubscription({
		plan: "pro", source: "play_store", environment: "test",
		expiresAt: future, subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
	}, now).productionPaid, false);
	assert.equal(evaluateSubscription({
		plan: "pro", source: "trial", environment: "production", expiresAt: future,
	}, now).productionPaid, false);
});

test("missing renewal metadata stays unknown instead of becoming cancelled", () => {
	const evaluated = evaluateSubscription({
		plan: "pro",
		source: "play_store",
		environment: "production",
		expiresAt: future,
		subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
	}, now);

	assert.equal(evaluated.entitled, true);
	assert.equal(evaluated.renewalState, "unknown");
	assert.equal(evaluated.renews, false);
});

test("verified provider payload is versioned and preserves renewal tri-state", () => {
	for (const [source, willAutoRenew, renewalState] of [
		["play_store", true, "renewing"],
		["app_store", false, "notRenewing"],
		["razorpay", undefined, "unknown"],
	]) {
		const payload = verifiedEntitlementPayload({
			plan: "pro",
			source,
			billingPeriod: "yearly",
			expiresAt: future,
			subscriptionState: "ACTIVE",
			...(willAutoRenew === undefined ? {} : { willAutoRenew }),
		}, now);
		assert.equal(payload.entitlementContractVersion, ENTITLEMENT_CONTRACT_VERSION);
		assert.equal(payload.renewalState, renewalState);
		assert.equal(
			payload.willAutoRenew,
			willAutoRenew === undefined ? null : willAutoRenew,
		);
	}
});
