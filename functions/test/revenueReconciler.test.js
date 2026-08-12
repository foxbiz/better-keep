const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const { aggregateRevenueTransactions } = require("../lib/revenueReconciler");

const at = Timestamp.fromDate(new Date("2026-08-08T00:00:00.000Z"));

test("rebuilds gross, refund, and net totals while quarantining exclusions", () => {
	const rebuilt = aggregateRevenueTransactions([
		{ provider: "razorpay", kind: "charge", amountMicros: 1855000000, currency: "INR", environment: "production", occurredAt: at, validationStatus: "verified" },
		{ provider: "razorpay", kind: "charge", amountMicros: 22980000, currency: "USD", environment: "production", occurredAt: at, validationStatus: "verified" },
		{ provider: "razorpay", kind: "refund", amountMicros: 19990000, currency: "USD", environment: "production", occurredAt: at, validationStatus: "verified" },
		{ provider: "razorpay", kind: "charge", amountMicros: 1500000000, currency: "INR", environment: "unknown", occurredAt: at, validationStatus: "excluded" },
	]);
	assert.deepEqual(rebuilt.lifetime.grossCurrencies, { INR: 1855000000, USD: 22980000 });
	assert.deepEqual(rebuilt.lifetime.refundCurrencies, { USD: 19990000 });
	assert.deepEqual(rebuilt.lifetime.netCurrencies, { INR: 1855000000, USD: 2990000 });
});
