const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
 canonicalStatusCleanupFieldNames,
	isDeletedAuthUserError,
 selectEffectiveEntitlements,
} = require("../lib/subscriptionReconciler");

const now = Date.parse("2026-08-08T00:00:00.000Z");
const expiry = (days) => Timestamp.fromMillis(now + days * 86400000);
const record = (source, days, state = "ACTIVE") => ({
	plan: "pro", source, environment: "production", expiresAt: expiry(days),
	subscriptionState: state, willAutoRenew: state === "ACTIVE",
});

test("preserves a valid primary provider while retaining overlapping access", () => {
	const selected = selectEffectiveEntitlements({
		now,
		current: record("app_store", 5),
		providerRecords: [
			{ id: "apple", data: record("app_store", 5) },
			{ id: "razor", data: record("razorpay", 30) },
		],
	});
	assert.equal(selected.active.length, 2);
	assert.equal(selected.primary.evaluated.source, "app_store");
});

test("expired old tokens cannot clobber a newer provider entitlement", () => {
	const selected = selectEffectiveEntitlements({
		now,
		current: record("play_store", -1, "SUBSCRIPTION_STATE_EXPIRED"),
		providerRecords: [
			{ id: "old-play", data: record("play_store", -1, "SUBSCRIPTION_STATE_EXPIRED") },
			{ id: "new-razor", data: record("razorpay", 30) },
		],
	});
	assert.equal(selected.active.length, 1);
	assert.equal(selected.primary.evaluated.source, "razorpay");
});

test("latest expiry and stable provider ordering select a deterministic primary", () => {
	const selected = selectEffectiveEntitlements({
		now,
		providerRecords: [
			{ id: "play", data: record("play_store", 10) },
			{ id: "apple", data: record("app_store", 20) },
		],
	});
 assert.equal(selected.primary.evaluated.source, "app_store");
});

test("verified Play replaces an active trial and ignores its longer expiry", () => {
 const selected = selectEffectiveEntitlements({
  now,
  current: {
   plan: "pro",
   source: "trial",
   expiresAt: expiry(30),
   billingPeriod: "trial",
  },
  providerRecords: [
   { id: "play", data: record("play_store", 5) },
  ],
 });

 assert.equal(selected.active.length, 1);
 assert.equal(selected.primary.evaluated.source, "play_store");
 assert.equal(selected.primary.evaluated.expiresAt.toMillis(), expiry(5).toMillis());
});

test("license-test Play purchases also replace an active trial", () => {
 const playTest = {
  ...record("play_store", 1),
  environment: "test",
 };
 const selected = selectEffectiveEntitlements({
  now,
  current: {
   plan: "pro",
   source: "trial",
   expiresAt: expiry(30),
  },
  providerRecords: [{ id: "play-test", data: playTest }],
 });

 assert.equal(selected.active.length, 1);
 assert.equal(selected.primary.evaluated.source, "play_store");
 assert.equal(selected.primary.evaluated.productionPaid, false);
});

test("trial never resumes after any paid provider history", () => {
 const selected = selectEffectiveEntitlements({
  now,
  current: {
   plan: "pro",
   source: "trial",
   expiresAt: expiry(7),
  },
  providerRecords: [
   { id: "expired-play", data: record("play_store", -1) },
  ],
 });

	assert.equal(selected.active.length, 0);
	assert.equal(selected.primary, null);
	assert.equal(selected.inactiveProvider.evaluated.source, "play_store");
});

test("trial remains active only when no paid provider history exists", () => {
	const selected = selectEffectiveEntitlements({
		now,
		current: {
			plan: "pro",
			source: "trial",
			expiresAt: expiry(7),
		},
		providerRecords: [],
	});

	assert.equal(selected.active.length, 1);
	assert.equal(selected.primary.evaluated.source, "trial");
});

test("provider reconciliation removes trial-only and legacy alias fields", () => {
 const fields = canonicalStatusCleanupFieldNames("play_store");

 assert.deepEqual(new Set(fields), new Set([
  "purchasePlatform",
  "expiryDate",
  "status",
  "autoRenew",
  "trialStartedAt",
  "trialExpiresAt",
 ]));
});

test("trial fallback retains its trial timestamps while normalizing aliases", () => {
 const fields = canonicalStatusCleanupFieldNames("trial");

 assert.equal(fields.includes("trialStartedAt"), false);
 assert.equal(fields.includes("trialExpiresAt"), false);
 assert.equal(fields.includes("purchasePlatform"), true);
});

test("an expired paid conversion does not recreate the consumed trial", () => {
 const selected = selectEffectiveEntitlements({
  now,
  current: record("play_store", -1, "SUBSCRIPTION_STATE_EXPIRED"),
  providerRecords: [
   { id: "expired-play", data: record("play_store", -1, "SUBSCRIPTION_STATE_EXPIRED") },
  ],
 });

 assert.equal(selected.active.length, 0);
 assert.equal(selected.primary, null);
});

test("deleted Firebase users are terminal claim-sync outcomes", () => {
	assert.equal(isDeletedAuthUserError({ code: "auth/user-not-found" }), true);
	assert.equal(isDeletedAuthUserError({ code: "auth/internal-error" }), false);
	assert.equal(isDeletedAuthUserError(new Error("user-not-found")), false);
});


test("Pro wins over longer Lite access even when Lite was primary", () => {
 const lite = {...record("razorpay", 365), plan: "lite"};
 const pro = record("app_store", 3);
 const selected = selectEffectiveEntitlements({now, current: lite,
  providerRecords: [{id:"lite",data:lite},{id:"pro",data:pro}]});
 assert.equal(selected.primary.evaluated.plan, "pro");
 assert.equal(selected.primary.evaluated.expiresAt.toMillis(), expiry(3).toMillis());
 const downgraded = selectEffectiveEntitlements({now, current: pro,
  providerRecords: [{id:"lite",data:lite},{id:"pro",data:record("app_store",-1)}]});
 assert.equal(downgraded.primary.evaluated.plan, "lite");
});


test("reconciliation writes the resolved tier to both status and Auth claims", async () => {
 const fs = require("node:fs");
 const vm = require("node:vm");
 const {createRequire} = require("node:module");
 const modulePath = require.resolve("../lib/subscriptionReconciler");
 const localRequire = createRequire(modulePath);
 for (const plan of ["free", "lite", "pro"]) {
  let status, claims;
  const document = (name) => ({
   collection: () => ({doc: () => document("status")}),
   get: async () => ({data: () => undefined}),
   set: async (data) => {if (name === "status") status = data;},
   delete: async () => {},
  });
  const records = plan === "free" ? [] : [{...record("app_store", 1), plan}];
  const db = {collection: () => ({
   doc: name => document(name),
   where: () => ({get: async () => ({docs: records.map((data, i) => ({id: String(i), data: () => data}))})}),
  })};
  const auth = {
   getUser: async () => ({customClaims: {plan: "pro", unrelated: true}}),
   setCustomUserClaims: async (_, value) => {claims = value;},
  };
  const module = {exports: {}};
  vm.runInNewContext(fs.readFileSync(modulePath, "utf8"), {
   module, exports: module.exports,
   require: (name) => {
    if (name === "./config") return {db, auth};
    assert.ok(["node:crypto", "firebase-admin/firestore", "./adminConfig", "./customClaims", "./subscriptionEntitlement"].includes(name));
    return localRequire(name);
   },
  });
  const result = await module.exports.reconcileUserEntitlement("memory-only", now, auth);
  assert.equal(result.plan, plan);
  assert.equal(status?.plan ?? "free", plan);
  assert.equal(claims.plan, plan);
  assert.equal(claims.unrelated, true);
 }
});
