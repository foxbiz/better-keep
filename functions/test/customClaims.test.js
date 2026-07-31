const assert = require("node:assert/strict");
const test = require("node:test");
const { mergeSubscriptionClaims } = require("../lib/customClaims");

test("subscription updates preserve the review authorization claim", () => {
	const expiresAt = new Date("2030-01-01T00:00:00.000Z");
	assert.deepEqual(
		mergeSubscriptionClaims(
			{ appReview: true, anotherClaim: "kept" },
			"pro",
			expiresAt,
		),
		{
			appReview: true,
			anotherClaim: "kept",
			plan: "pro",
			planExpiresAt: expiresAt.getTime(),
		},
	);
});

test("free subscription clears only subscription expiry", () => {
	assert.deepEqual(
		mergeSubscriptionClaims({ appReview: true }, "free", null),
		{
			appReview: true,
			plan: "free",
			planExpiresAt: null,
		},
	);
});
