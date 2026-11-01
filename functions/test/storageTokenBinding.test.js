const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
	storageRefreshBinding,
	signStorageGrant,
	verifyStorageGrant,
} = require("../lib/storageTokenBinding");
const context = {
	uid: "user",
	provider: "google_drive",
	connectionId: "google_drive",
};
const key = "test-only-secret",
	client = "client",
	token = "private-test-refresh";
const fingerprint = storageRefreshBinding(key, context, client, 1, token);
const receipt = signStorageGrant(key, context, client, 1, fingerprint, 1000);
test("receipt binds user, provider, connection, client, generation without disclosing token", () => {
	assert.equal(
		verifyStorageGrant(key, context, client, 1, receipt, 1000),
		fingerprint,
	);
	assert.equal(
		verifyStorageGrant(
			key,
			{ ...context, deviceId: "another-approved-device" },
			client,
			1,
			receipt,
			1000,
		),
		fingerprint,
	);
	assert(
		!Buffer.from(receipt.split(".")[0], "base64url").toString().includes(token),
	);
	for (const patch of [
		{ uid: "attacker" },
		{ provider: "dropbox" },
		{ connectionId: "other" },
	]) {
		assert.throws(
			() =>
				verifyStorageGrant(
					key,
					{ ...context, ...patch },
					client,
					1,
					receipt,
					1000,
				),
			/denied/,
		);
		assert.notEqual(
			storageRefreshBinding(key, { ...context, ...patch }, client, 1, token),
			fingerprint,
		);
	}
	for (const [k, c, g] of [
		["wrong-key", client, 1],
		[key, "wrong-client", 1],
		[key, client, 2],
	])
		assert.throws(
			() => verifyStorageGrant(k, context, c, g, receipt, 1000),
			/denied/,
		);
	assert.notEqual(
		storageRefreshBinding(key, context, client, 1, "other-token"),
		fingerprint,
	);
});
test("expired, tampered, malformed and unsupported receipts fail closed", () => {
	assert.throws(
		() => verifyStorageGrant(key, context, client, 1, receipt, 601000),
		/denied/,
	);
	for (const input of [
		null,
		"",
		receipt + ".extra",
		receipt.slice(0, -1) + "z",
		receipt.replace(/^./, "x"),
		"x".repeat(4097),
	])
		assert.throws(
			() => verifyStorageGrant(key, context, client, 1, input, 1000),
			/denied/,
		);
	assert.throws(
		() => verifyStorageGrant("", context, client, 1, receipt, 1000),
		/unavailable/,
	);
});
