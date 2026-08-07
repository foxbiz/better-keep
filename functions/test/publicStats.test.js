const assert = require("node:assert/strict");
const test = require("node:test");
const {
	compactPublicUserCount,
	createPublicStatsPayload,
	isPublicStatsOriginAllowed,
} = require("../lib/publicStats");

test("allows Better Keep production, preview, and local origins", () => {
	for (const origin of [
		undefined,
		"https://betterkeep.app",
		"https://better-keep-notes.web.app",
		"https://better-keep-notes.firebaseapp.com",
		"https://better-keep-notes--ui-overhaul-bxmkn7jk.web.app",
		"http://localhost:4321",
		"http://127.0.0.1:5002",
	]) {
		assert.equal(isPublicStatsOriginAllowed(origin), true, origin);
	}
});

test("rejects unrelated and lookalike origins", () => {
	for (const origin of [
		"https://example.com",
		"https://other-project--ui-overhaul.web.app",
		"https://better-keep-notes--ui-overhaul.web.app.evil.example",
		"http://better-keep-notes--ui-overhaul.web.app",
		"http://localhost:9999",
	]) {
		assert.equal(isPublicStatsOriginAllowed(origin), false, origin);
	}
});

test("formats privacy-rounded counts as compact metrics", () => {
	assert.equal(compactPublicUserCount("4200+"), "4.2K+");
	assert.equal(compactPublicUserCount("4500+"), "4.5K+");
	assert.equal(compactPublicUserCount("1000+"), "1K+");
	assert.equal(compactPublicUserCount("12500+"), "12.5K+");
	assert.equal(compactPublicUserCount("1200000+"), "1.2M+");
	assert.equal(compactPublicUserCount("950+"), "950+");
	assert.equal(compactPublicUserCount("4.2k+"), "4.2K+");
	for (const value of ["0", "error", "4.22K+", "users", "", null, 4200]) {
		assert.equal(compactPublicUserCount(value), null, String(value));
	}
});

test("keeps the Shields response contract and adds an optional metric", () => {
	assert.deepEqual(createPublicStatsPayload("4200+"), {
		schemaVersion: 1,
		label: "users",
		message: "4200+",
		color: "blue",
		metric: "4.2K+",
	});
	assert.deepEqual(createPublicStatsPayload("error", "red"), {
		schemaVersion: 1,
		label: "users",
		message: "error",
		color: "red",
	});
});
