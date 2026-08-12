const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
	canonicalSubscriptionFields,
	summarizeSubscription,
} = require("../lib/adminSubscription");

const now = Date.parse("2026-08-08T00:00:00.000Z");
const future = Timestamp.fromDate(new Date("2099-08-08T00:00:00.000Z"));
const past = Timestamp.fromDate(new Date("2020-08-08T00:00:00.000Z"));

test("classifies current paid and cancelled entitlements", () => {
	assert.deepEqual(
		summarizeSubscription(
			{
				plan: "pro",
				source: "razorpay",
				environment: "production",
				expiresAt: future,
				willAutoRenew: false,
				subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
				billingPeriod: "monthly",
			},
			now,
		),
		{
			plan: "pro",
			source: "razorpay",
			entitlementState: "cancelled_access",
			environment: "production",
			expiresAt: future,
			state: "SUBSCRIPTION_STATE_CANCELED",
			billingPeriod: "monthly",
			subscriptionClass: "paid",
			renewalState: "cancelled",
		},
	);
});

test("excludes trials and expired records from paid totals", () => {
	assert.equal(
		summarizeSubscription({ plan: "pro", source: "trial", expiresAt: future }, now)
			.subscriptionClass,
		"trial",
	);
	assert.equal(
		summarizeSubscription({ plan: "pro", source: "app_store", environment: "production", expiresAt: past }, now)
			.subscriptionClass,
		"free",
	);
});

test("normalizes legacy expiry and renewal fields", () => {
	const canonical = canonicalSubscriptionFields({
		plan: "pro",
		source: "razorpay",
		environment: "production",
		expiryDate: future,
		autoRenew: true,
		billingPeriod: "yearly",
	});
	assert.equal(canonical.expiresAt, future);
	assert.equal(canonical.willAutoRenew, true);
	assert.equal(canonical.billingPeriod, "yearly");
	assert.equal(canonical.environment, "production");
});
