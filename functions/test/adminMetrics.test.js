const assert = require("node:assert/strict");
const test = require("node:test");
const { mergedRevenueProviderStatus } = require("../lib/adminMetrics");

test("provider status migration reads legacy dotted fields", () => {
	assert.deepEqual(
		mergedRevenueProviderStatus({
			"revenueProviderStatus.play_store": { status: "ready" },
			"revenueProviderStatus.razorpay": { status: "degraded" },
		}),
		{
			play_store: { status: "ready" },
			razorpay: { status: "degraded" },
		},
	);
});

test("nested provider status wins while both formats are supported", () => {
	const result = mergedRevenueProviderStatus({
		"revenueProviderStatus.play_store": { status: "legacy" },
		revenueProviderStatus: {
			play_store: { status: "ready" },
			app_store: { status: "ready" },
		},
	});
	assert.equal(result.play_store.status, "ready");
	assert.equal(result.app_store.status, "ready");
});
