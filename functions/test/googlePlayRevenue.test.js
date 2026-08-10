const assert = require("node:assert/strict");
const test = require("node:test");
const { strToU8, zipSync } = require("fflate");
const {
	isGooglePlaySubscriptionSalesRow,
	parseGooglePlayRevenueRow,
	parseGooglePlaySalesArchive,
	normalizeGooglePlayReportBucket,
} = require("../lib/googlePlayRevenue");

const base = {
	"Package ID": "io.foxbiz.better_keep",
	"Product Type": "Subscription",
	"Order Number": "GPA.1234-5678-9012-34567..0",
	"Currency of Sale": "USD",
	"Charged Amount": "2.99",
	"Order Charged Timestamp": "1786147200",
	"SKU ID": "better_keep_pro",
};

test("parses charged Google Play subscription rows", () => {
	const parsed = parseGooglePlayRevenueRow({ ...base, "Financial Status": "Charged" });
	assert.equal(parsed.kind, "charge");
	assert.equal(parsed.amountMicros, 2990000);
	assert.equal(parsed.currency, "USD");
	assert.match(parsed.providerTransactionId, /:charge$/);
});

test("accepts the Play Console gs URI without sending it to Storage verbatim", () => {
	assert.equal(
		normalizeGooglePlayReportBucket("gs://pubsite_prod_rev_123456789/"),
		"pubsite_prod_rev_123456789",
	);
	assert.equal(
		normalizeGooglePlayReportBucket("gs://pubsite_prod_123456789/sales/"),
		"pubsite_prod_123456789",
	);
	assert.equal(
		normalizeGooglePlayReportBucket("pubsite_prod_123456789"),
		"pubsite_prod_123456789",
	);
	assert.throws(() => normalizeGooglePlayReportBucket("other-bucket"));
	assert.throws(() =>
		normalizeGooglePlayReportBucket("gs://pubsite_prod_123/reviews/"),
	);
});

test("keeps refunds separate and skips unrelated products", () => {
	const refund = parseGooglePlayRevenueRow({
		...base,
		"Financial Status": "Refund",
		"Charged Amount": "-2.99",
	});
	assert.equal(refund.kind, "refund");
	assert.match(refund.providerTransactionId, /:refund:/);
	assert.equal(
		parseGooglePlayRevenueRow({ ...base, "Package ID": "other.app" }),
		null,
	);
});

test("filters report recovery to Better Keep subscription orders", () => {
	assert.equal(isGooglePlaySubscriptionSalesRow(base), true);
	assert.equal(
		isGooglePlaySubscriptionSalesRow({ ...base, "Package ID": "other.app" }),
		false,
	);
	assert.equal(
		isGooglePlaySubscriptionSalesRow({ ...base, "Product Type": "In-app product" }),
		false,
	);
});

test("extracts a CSV from the Play report ZIP archive", () => {
	const csv = `${Object.keys(base).join(",")},Financial Status\n${Object.values(base).join(",")},Charged\n`;
	const archive = Buffer.from(zipSync({ "sales.csv": strToU8(csv) }));
	const rows = parseGooglePlaySalesArchive(archive);
	assert.equal(rows.length, 1);
	assert.equal(rows[0]["Order Number"], base["Order Number"]);
});
