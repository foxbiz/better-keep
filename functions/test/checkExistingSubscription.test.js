const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
 existingSubscriptionResponse,
} = require("../lib/exports/checkExistingSubscription");
const { ENTITLEMENT_CONTRACT_VERSION } = require("../lib/subscriptionEntitlement");

const now = Date.parse("2026-08-10T00:00:00.000Z");
const future = Timestamp.fromMillis(now + 86400000);

test("reports a remaining trial only when it is canonical", () => {
 assert.deepEqual(
  existingSubscriptionResponse(
   { plan: "pro", source: "trial", expiresAt: future },
   now,
  ),
  {
   entitlementContractVersion: ENTITLEMENT_CONTRACT_VERSION,
   hasSubscription: false,
   isTrial: true,
   resolution: "trial",
  },
 );
});

test("reports a reconciled Play subscription instead of trial", () => {
 const response = existingSubscriptionResponse(
  {
   plan: "pro",
   source: "play_store",
   billingPeriod: "yearly",
   expiresAt: future,
   willAutoRenew: false,
   subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
  },
  now,
 );

 assert.equal(response.hasSubscription, true);
 assert.deepEqual(response.subscription, {
  billingPeriod: "yearly",
  entitlementContractVersion: ENTITLEMENT_CONTRACT_VERSION,
  expiresAt: future.toDate().toISOString(),
  plan: "pro",
  renewalState: "notRenewing",
  source: "play_store",
  subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
  willAutoRenew: false,
 });
 assert.equal(response.resolution, "active_provider");
 assert.equal(response.entitlementContractVersion, ENTITLEMENT_CONTRACT_VERSION);
});

test("reports explicit terminal provider state separately from no record", () => {
 const response = existingSubscriptionResponse(undefined, now, {
  activeSources: [],
  entitlementState: "ended",
  expiresAt: null,
  plan: "free",
  primarySource: "play_store",
  providerState: "SUBSCRIPTION_STATE_EXPIRED",
  renewalState: "unknown",
  resolution: "provider_inactive",
 });

 assert.equal(response.hasSubscription, false);
 assert.equal(response.resolution, "provider_inactive");
 assert.equal(response.providerState, "SUBSCRIPTION_STATE_EXPIRED");
 assert.equal(response.renewalState, "unknown");
});
