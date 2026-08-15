const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
	appStoreBillingActivityType,
	billingActivityData,
	billingActivityId,
	historicalPlayChargeType,
	playBillingActivityType,
	razorpayBillingActivityType,
} = require("../lib/billingActivity");

test("billing activity IDs are deterministic and do not expose provider IDs", () => {
	const raw = "GPA.1234-5678-9012-34567..0";
	const first = billingActivityId("play_store", raw);
	assert.equal(first, billingActivityId("play_store", raw));
	assert.notEqual(first, billingActivityId("app_store", raw));
	assert.equal(first.length, 64);
	assert.doesNotMatch(first, /GPA|1234/);
});

test("provider notifications map purchases and renewals to distinct events", () => {
	assert.equal(playBillingActivityType(4), "purchase");
	assert.equal(playBillingActivityType(2), "renewal");
	assert.equal(playBillingActivityType(6), "grace");
	assert.equal(appStoreBillingActivityType("SUBSCRIBED", null), "purchase");
	assert.equal(appStoreBillingActivityType("SUBSCRIBED", "RESUBSCRIBE"), "restart");
	assert.equal(appStoreBillingActivityType("DID_RENEW", null), "renewal");
	assert.equal(appStoreBillingActivityType("DID_RECOVER", null), "recovery");
	assert.equal(
		appStoreBillingActivityType("GRACE_PERIOD_EXPIRED", null),
		"expiration",
	);
	assert.equal(
		appStoreBillingActivityType("DID_CHANGE_RENEWAL_PREF", null),
		"plan_change",
	);
	assert.equal(
		razorpayBillingActivityType("subscription.authenticated", false),
		"purchase",
	);
	assert.equal(
		razorpayBillingActivityType("subscription.authenticated", true),
		"purchase",
	);
	assert.equal(
		razorpayBillingActivityType("subscription.charged", true),
		"renewal",
	);
});

test("historical Play charges use subscription start time to infer purchases", () => {
	const chargedAt = new Date("2026-08-15T12:00:00.000Z");
	assert.equal(
		historicalPlayChargeType("2026-08-15T10:00:00.000Z", chargedAt),
		"purchase",
	);
	assert.equal(
		historicalPlayChargeType("2026-04-14T10:00:00.000Z", chargedAt),
		"renewal",
	);
});

test("normalized billing activity keeps money paired and currencies separate", () => {
	const now = Timestamp.fromMillis(1);
	const data = billingActivityData(
		{
			provider: "play_store",
			eventKey: "event-one",
			eventType: "renewal",
			occurredAt: new Date("2026-08-15T12:00:00.000Z"),
			amountMicros: 2_990_000,
			currency: "eur",
		},
		now,
	);
	assert.equal(data.currency, "EUR");
	assert.equal(data.amountMicros, 2_990_000);
	assert.equal(data.createdAt, now);
	assert.throws(
		() =>
			billingActivityData({
				provider: "play_store",
				eventKey: "event-two",
				eventType: "renewal",
				occurredAt: new Date(),
				amountMicros: 2_990_000,
			}),
		/amount and currency/,
	);
});
