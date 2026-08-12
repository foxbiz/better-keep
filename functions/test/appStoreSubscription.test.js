const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
	appStoreEffectiveExpiryMillis,
	appStoreWillAutoRenew,
	resolveAppStoreNotification,
} = require("../lib/appStoreSubscription");
const { evaluateSubscription } = require("../lib/subscriptionEntitlement");

const now = Date.parse("2026-08-09T00:00:00.000Z");
const future = now + 30 * 86_400_000;

test("refunds and revocations end access at the authoritative termination time", () => {
	for (const notificationType of ["REFUND", "REVOKE"]) {
		const decision = resolveAppStoreNotification(notificationType, null);
		assert.equal(decision.kind, "state_change");
		assert.equal(decision.subscriptionState, "SUBSCRIPTION_STATE_REVOKED");
		const expiresAt = appStoreEffectiveExpiryMillis({
			decision,
			now,
			providerExpiryMillis: future,
			revocationDateMillis: now - 1_000,
		});
		assert.equal(expiresAt, now - 1_000);
		assert.equal(
			evaluateSubscription(
				{
					plan: "pro",
					source: "app_store",
					environment: "production",
					subscriptionState: decision.subscriptionState,
					expiresAt: Timestamp.fromMillis(expiresAt),
				},
				now,
			).entitled,
			false,
		);
	}
});

test("a refund without a revocation timestamp cannot retain its old future expiry", () => {
	const decision = resolveAppStoreNotification("REFUND", null);
	assert.equal(
		appStoreEffectiveExpiryMillis({
			decision,
			now,
			providerExpiryMillis: future,
			notificationSignedDateMillis: now - 500,
		}),
		now - 500,
	);
});

test("cancellation disables renewal while preserving access through expiry", () => {
	const decision = resolveAppStoreNotification(
		"DID_CHANGE_RENEWAL_STATUS",
		"AUTO_RENEW_DISABLED",
	);
	assert.equal(decision.kind, "state_change");
	assert.equal(decision.subscriptionState, "SUBSCRIPTION_STATE_CANCELED");
	assert.equal(appStoreWillAutoRenew(decision, 0), false);
	assert.equal(
		evaluateSubscription(
			{
				plan: "pro",
				source: "app_store",
				environment: "production",
				subscriptionState: decision.subscriptionState,
				expiresAt: Timestamp.fromMillis(future),
				willAutoRenew: false,
			},
			now,
		).entitlementState,
		"cancelled_access",
	);
});

test("expiry and non-grace billing failure do not grant access", () => {
	assert.equal(
		resolveAppStoreNotification("EXPIRED", null).subscriptionState,
		"SUBSCRIPTION_STATE_EXPIRED",
	);
	assert.equal(
		resolveAppStoreNotification("DID_FAIL_TO_RENEW", null).subscriptionState,
		"SUBSCRIPTION_STATE_PENDING",
	);
});

test("grace period remains entitled and observes explicit renewal status", () => {
	const decision = resolveAppStoreNotification(
		"DID_FAIL_TO_RENEW",
		"GRACE_PERIOD",
	);
	assert.equal(decision.subscriptionState, "SUBSCRIPTION_STATE_IN_GRACE_PERIOD");
	assert.equal(appStoreWillAutoRenew(decision, 1), true);
	assert.equal(appStoreWillAutoRenew(decision, 0), false);
});

test("informational notifications preserve entitlement metadata", () => {
	for (const notificationType of [
		"DID_CHANGE_RENEWAL_PREF",
		"OFFER_REDEEMED",
		"PRICE_INCREASE",
		"RENEWAL_EXTENDED",
		"RENEWAL_EXTENSION",
	]) {
		assert.deepEqual(resolveAppStoreNotification(notificationType, null), {
			kind: "metadata_only",
		});
	}
});

test("unknown notifications and renewal-status subtypes fail open for access", () => {
	assert.deepEqual(resolveAppStoreNotification("FUTURE_APPLE_EVENT", null), {
		kind: "unknown",
	});
	assert.deepEqual(
		resolveAppStoreNotification("DID_CHANGE_RENEWAL_STATUS", "FUTURE_SUBTYPE"),
		{ kind: "unknown" },
	);
});
