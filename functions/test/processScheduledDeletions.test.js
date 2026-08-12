const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const {
	executeUserDeletion,
	isNotFoundError,
} = require("../lib/exports/processScheduledDeletions");

function operations(calls, failure) {
	return Object.fromEntries(
		["deleteSubcollections", "deleteStorage", "deleteAuthUser", "deleteFirestoreRoots"].map(
			(name) => [name, async () => {
				calls.push(name);
				if (failure === name) throw new Error(`${name} failed`);
			}],
		),
	);
}

test("deletion preserves Firestore roots until every external step succeeds", async () => {
	for (const failure of ["deleteSubcollections", "deleteStorage", "deleteAuthUser"]) {
		const calls = [];
		await assert.rejects(() => executeUserDeletion("user-1", operations(calls, failure)));
		assert.equal(calls.includes("deleteFirestoreRoots"), false, `${failure} must retain retry marker`);
	}
});

test("a retry converges after an earlier external failure", async () => {
	const failedCalls = [];
	await assert.rejects(
		() => executeUserDeletion("user-1", operations(failedCalls, "deleteAuthUser")),
	);
	const retryCalls = [];
	await executeUserDeletion("user-1", operations(retryCalls));
	assert.deepEqual(retryCalls, [
		"deleteSubcollections",
		"deleteStorage",
		"deleteAuthUser",
		"deleteFirestoreRoots",
	]);
});

test("only documented absence errors are treated as not found", () => {
	assert.equal(isNotFoundError({ code: "auth/user-not-found" }), true);
	assert.equal(isNotFoundError({ code: "storage/object-not-found" }), true);
	assert.equal(isNotFoundError({ code: 404 }), true);
	assert.equal(isNotFoundError({ code: "auth/internal-error" }), false);
});

test("the scheduled wrapper retries failures and recursively removes descendants", () => {
	const source = readFileSync("src/exports/processScheduledDeletions.ts", "utf8");
	assert.match(source, /retryCount: 5/);
	assert.match(source, /db\.recursiveDelete\(subcollection\)/);
	assert.match(source, /if \(results\.failed > 0\)[\s\S]{0,120}throw new Error/);
});
