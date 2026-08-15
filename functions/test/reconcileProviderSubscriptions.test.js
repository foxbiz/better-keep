const assert = require("node:assert/strict");
const test = require("node:test");
const {
	reconcileUsersIndependently,
} = require("../lib/exports/reconcileProviderSubscriptions");

test("one historical user failure cannot abort remaining reconciliation", async () => {
	const visited = [];
	const failures = [];
	const count = await reconcileUsersIndependently(
		["first", "deleted", "last"],
		async (userId) => {
			visited.push(userId);
			if (userId === "deleted") throw Object.assign(new Error("missing"), {
				code: "auth/user-not-found",
			});
		},
		(userId, error) => failures.push([userId, error.code]),
	);
	assert.deepEqual(new Set(visited), new Set(["first", "deleted", "last"]));
	assert.deepEqual(failures, [["deleted", "auth/user-not-found"]]);
	assert.equal(count, 1);
});
