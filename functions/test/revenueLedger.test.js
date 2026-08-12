const assert = require("node:assert/strict");
const test = require("node:test");
const {
	decimalToMicros,
	minorUnitsToMicros,
	monthKey,
	revenueContributions,
	revenueSummaryAmounts,
} = require("../lib/revenueLedger");

test("normalizes provider amounts to integer micros", () => {
	assert.equal(minorUnitsToMicros(299), 2990000);
	assert.equal(decimalToMicros("1,625.50"), 1625500000);
	assert.equal(decimalToMicros("0.000001"), 1);
	assert.throws(() => decimalToMicros("1.1234567"));
});

test("keeps gross, refunds, and net separate without currency conversion", () => {
	assert.deepEqual(
		revenueContributions({
			environment: "production",
			kind: "refund",
			amountMicros: 19990000,
		}),
		{ gross: 0, refunds: 19990000, net: -19990000 },
	);
	assert.deepEqual(
		revenueContributions({
			environment: "unknown",
			kind: "charge",
			amountMicros: 1500000000,
			validationStatus: "excluded",
		}),
		{ gross: 0, refunds: 0, net: 0 },
	);
	assert.deepEqual(revenueSummaryAmounts({ currencies: { INR: 1855000000 } }), {
		grossCurrencies: { INR: 1855000000 },
		refundCurrencies: {},
		netCurrencies: { INR: 1855000000 },
	});
});

test("uses UTC calendar months", () => {
	assert.equal(monthKey(new Date("2026-08-31T23:59:59.999Z")), "2026-08");
	assert.equal(monthKey(new Date("2026-09-01T00:00:00.000Z")), "2026-09");
});
