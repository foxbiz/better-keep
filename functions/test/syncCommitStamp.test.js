const assert = require("node:assert/strict");
const test = require("node:test");
const { needsSyncCommitStamp } = require("../lib/syncCommitStamp");

test("stamps legacy creates and updates without a marker", () => {
	assert.equal(needsSyncCommitStamp(undefined, undefined), true);
	assert.equal(
		needsSyncCommitStamp({ seconds: 10, nanoseconds: 20 }, undefined),
		true,
	);
});

test("stamps legacy updates that preserve the previous marker", () => {
	const marker = { seconds: 10, nanoseconds: 20 };
	assert.equal(needsSyncCommitStamp(marker, { ...marker }), true);
});

test("does not restamp new-client writes or the trigger's own write", () => {
	assert.equal(
		needsSyncCommitStamp(undefined, { seconds: 10, nanoseconds: 20 }),
		false,
	);
	assert.equal(
		needsSyncCommitStamp(
			{ seconds: 10, nanoseconds: 20 },
			{ seconds: 10, nanoseconds: 21 },
		),
		false,
	);
});

test("treats malformed markers as legacy writes", () => {
	assert.equal(
		needsSyncCommitStamp(
			{ seconds: 10, nanoseconds: 20 },
			"not-a-timestamp",
		),
		true,
	);
});
