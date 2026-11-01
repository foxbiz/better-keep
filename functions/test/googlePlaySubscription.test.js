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


test("Lite tier derives from verified product and base plan, not caller selection", () => {
 const normalize = (productId, basePlanId) => normalizeGooglePlaySubscription({
  purchaseToken:"test",userId:"uid",now:Date.parse("2026-08-08"),
  resource:{subscriptionState:"SUBSCRIPTION_STATE_ACTIVE",lineItems:[{
   productId,expiryTime:future,offerDetails:{basePlanId},
  }]}});
 assert.equal(normalize("better_keep_lite","lite-yearly").plan,"lite");
 assert.equal(normalize("better_keep_lite","lite-yearly").billingPeriod,"yearly");
 assert.equal(normalize("better_keep_lite","pro-monthly").plan,"free");
 assert.equal(normalize("unknown","pro-monthly").plan,"free");
});


test("unknown Play products cannot overwrite an existing paid record", async () => {
  const { db } = require("../lib/config");
  const { persistVerifiedGooglePlaySubscription, GooglePlayPermanentError } = require("../lib/googlePlayService");
  const originalCollection = db.collection;
  const originalTransaction = db.runTransaction;
  let writes = 0;
  const existing = {userId: "uid", plan: "pro", source: "play_store"};
  db.collection = (name) => {
    assert.equal(name, "subscriptions");
    return {doc: () => ({get: async () => ({exists: true, data: () => existing})})};
  };
  db.runTransaction = async () => { writes++; throw new Error("Unexpected write"); };
  try {
    await assert.rejects(() => persistVerifiedGooglePlaySubscription({
      purchaseToken: "qa-token", requestedUserId: "uid", userExists: async () => true,
      resource: {subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
        externalAccountIdentifiers: {obfuscatedExternalAccountId: "uid"},
        lineItems: [{productId: "unknown", expiryTime: future, offerDetails: {basePlanId: "unknown"}}]},
      reconcile: false,
    }), GooglePlayPermanentError);
    assert.equal(writes, 0);
    assert.equal(existing.plan, "pro");
  } finally {
    db.collection = originalCollection;
    db.runTransaction = originalTransaction;
  }
});
