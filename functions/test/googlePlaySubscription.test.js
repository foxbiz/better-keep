const assert = require("node:assert/strict");
const test = require("node:test");
const {
	googlePlayAccountId,
	normalizeGooglePlaySubscription,
} = require("../lib/googlePlaySubscription");
const { verifiedFirebaseUserId } = require("../lib/googlePlayService");

const future = "2026-09-08T00:00:00.000Z";

test("normalizes authoritative Play state, renewal, expiry, and account identity", () => {
	const resource = {
		subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
		externalAccountIdentifiers: { obfuscatedExternalAccountId: "firebase-uid" },
		lineItems: [{
			productId: "better_keep_pro",
			expiryTime: future,
			autoRenewingPlan: { autoRenewEnabled: false },
			offerDetails: { basePlanId: "pro-yearly" },
		}],
	};
	const normalized = normalizeGooglePlaySubscription({
		purchaseToken: "secret-token", resource, userId: "firebase-uid",
		now: Date.parse("2026-08-08T00:00:00.000Z"),
	});
	assert.equal(normalized.entitlementState, "cancelled_access");
	assert.equal(normalized.willAutoRenew, false);
	assert.equal(normalized.renewalState, "notRenewing");
	assert.equal(normalized.billingPeriod, "yearly");
	assert.equal(normalized.externalAccountVerified, true);
	assert.equal(googlePlayAccountId(resource), "firebase-uid");
});

test("missing Play auto-renew metadata remains unknown", () => {
	const normalized = normalizeGooglePlaySubscription({
		purchaseToken: "token-without-renewal",
		resource: {
			subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
			lineItems: [{
				productId: "better_keep_pro",
				expiryTime: future,
				offerDetails: { basePlanId: "pro-yearly" },
			}],
		},
		userId: "uid",
		now: Date.parse("2026-08-08T00:00:00.000Z"),
	});

	assert.equal(normalized.renewalState, "unknown");
	assert.equal(normalized.willAutoRenew, null);
});

test("license-test purchases are never marked as production", () => {
	const normalized = normalizeGooglePlaySubscription({
		purchaseToken: "token",
		resource: {
			testPurchase: {},
			subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
			lineItems: [{ expiryTime: future, autoRenewingPlan: { autoRenewEnabled: true } }],
		},
		userId: null,
	});
	assert.equal(normalized.environment, "test");
	assert.equal(normalized.externalAccountVerified, false);
});

test("preverified Firebase ownership avoids a second provider lookup", async () => {
	let calls = 0;
	assert.equal(
		await verifiedFirebaseUserId("uid-linked", async (uid) => {
			calls += 1;
			return uid === "uid-linked";
		}),
		"uid-linked",
	);
	assert.equal(
		await verifiedFirebaseUserId("uid-deleted", async () => {
			calls += 1;
			return false;
		}),
		null,
	);
	assert.equal(await verifiedFirebaseUserId(null), null);
	assert.equal(calls, 2);
});
