const assert = require("node:assert/strict");
const { test } = require("node:test");
const { randomUUID } = require("node:crypto");

// Never read credentials, call Play, or write a production database.
const isolated = process.env.FIRESTORE_EMULATOR_HOST &&
  process.env.GCLOUD_PROJECT?.startsWith("demo-") &&
  process.env.FUNCTIONS_EMULATOR === "true";

test("Play replacement retires old access atomically and rejects conflicting ownership", {
  skip: !isolated,
}, async (t) => {
  const { app, db } = require("../lib/config");
  const { persistVerifiedGooglePlaySubscription: persist } = require("../lib/googlePlayService");
  const { selectEffectiveEntitlements } = require("../lib/subscriptionReconciler");
  const { evaluateSubscription, verifiedEntitlementPayload } = require("../lib/subscriptionEntitlement");
  const prefix = `replacement-${randomUUID()}`;
  const uid = `${prefix}-owner`;
  const tokens = new Set();
  const ref = token => { tokens.add(token); return db.collection("subscriptions").doc(token); };
  const resource = (plan, previous, state = "SUBSCRIPTION_STATE_ACTIVE") => ({
    externalAccountIdentifiers: { obfuscatedExternalAccountId: uid },
    subscriptionState: state, linkedPurchaseToken: previous,
    lineItems: [{ productId: `better_keep_${plan}`,
      expiryTime: new Date(Date.now() + 86400000).toISOString(),
      offerDetails: { basePlanId: `${plan}-monthly` },
      autoRenewingPlan: { autoRenewEnabled: true } }],
  });
  const save = (token, data) => {
    ref(token);
    if (data.linkedPurchaseToken) ref(data.linkedPurchaseToken);
    return persist({ purchaseToken: token, resource: data,
      requestedUserId: uid, reconcile: false, userExists: async id => id === uid });
  };
  try {
    await t.test("downgrade, late old event, and expiry cannot resurrect Pro", async () => {
      const old = `${prefix}-pro`, next = `${prefix}-lite`;
      await save(old, resource("pro"));
      await save(next, resource("lite", old));
      assert.equal((await ref(old).get()).data().supersededByPurchaseToken, next);
      const late = await save(old, resource("pro"));
      assert.equal(late.entitled, false);
      assert.equal(verifiedEntitlementPayload(late.data), null);
      const records = async () => Promise.all([old, next].map(async id => ({id, data: (await ref(id).get()).data()})));
      assert.equal(selectEffectiveEntitlements({providerRecords: await records()}).primary.evaluated.plan, "lite");
      await save(next, resource("lite", old, "SUBSCRIPTION_STATE_EXPIRED"));
      assert.equal((await save(old, resource("pro"))).entitled, false);
      assert.equal(selectEffectiveEntitlements({providerRecords: await records()}).primary, null);
    });
    await t.test("new token arriving before the old one retains its retirement marker", async () => {
      const old = `${prefix}-unseen`, next = `${prefix}-upgrade`;
      await save(next, resource("pro", old));
      assert.equal((await save(old, resource("lite"))).entitled, false);
      assert.equal(evaluateSubscription((await ref(next).get()).data()).plan, "pro");
    });
    await t.test("pending replacement never retires paid access", async () => {
      const old = `${prefix}-active`, next = `${prefix}-pending`;
      await save(old, resource("pro"));
      await save(next, resource("lite", old, "SUBSCRIPTION_STATE_PENDING"));
      assert.equal(evaluateSubscription((await ref(old).get()).data()).entitled, true);
      assert.equal((await ref(old).get()).data().supersededByPurchaseToken, undefined);
    });
    await t.test("another account's old purchase rejects the entire transaction", async () => {
      const old = `${prefix}-foreign`, next = `${prefix}-rejected`;
      await ref(old).set({userId: "another-account", source: "play_store"});
      await assert.rejects(save(next, resource("lite", old)), {code: "failed-precondition"});
      assert.equal((await ref(next).get()).exists, false);
      assert.equal((await ref(old).get()).data().userId, "another-account");
    });
    await t.test("concurrent conflicting successors cannot retire the same purchase twice", async () => {
      const old = `${prefix}-shared`, first = `${prefix}-first`, second = `${prefix}-second`;
      const results = await Promise.allSettled([
        save(first, resource("lite", old)), save(second, resource("pro", old)),
      ]);
      assert.equal(results.filter(result => result.status === "fulfilled").length, 1);
      const rejected = results.find(result => result.status === "rejected");
      assert.equal(rejected.reason.code, "failed-precondition");
      const winningToken = results[0].status === "fulfilled" ? first : second;
      const losingToken = winningToken === first ? second : first;
      assert.equal((await ref(losingToken).get()).exists, false);
      assert.equal((await ref(old).get()).data().supersededByPurchaseToken, winningToken);
    });
  } finally {
    await Promise.all([...tokens].map(token => db.collection("subscriptions").doc(token).delete()));
    await db.terminate();
    await app.delete();
  }
});
