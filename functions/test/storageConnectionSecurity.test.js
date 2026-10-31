const { test } = require("node:test");
const assert = require("node:assert/strict");
const { createHash, randomBytes } = require("node:crypto");
const {
	storageCapabilityHash,
	verifyStorageCapability,
} = require("../lib/storageConnectionSecurity");
test("capability hashes remain compatible with existing grants and isolate users/providers", () => {
	const capability = randomBytes(32).toString("base64url");
	const context = {
		uid: "user",
		provider: "google_drive",
		connectionId: "google_drive",
	};
	const legacy = createHash("sha256")
		.update(
			JSON.stringify([
				"better-keep/storage-vault",
				1,
				"capability-v1",
				"user",
				"google_drive",
				"google_drive",
			]),
		)
		.update(capability)
		.digest("hex");
	assert.equal(storageCapabilityHash(context, capability), legacy);
	assert.equal(verifyStorageCapability(context, capability, legacy), true);
	assert.equal(
		verifyStorageCapability({ ...context, uid: "other" }, capability, legacy),
		false,
	);
	assert.equal(
		verifyStorageCapability(
			{ ...context, provider: "dropbox" },
			capability,
			legacy,
		),
		false,
	);
	assert.equal(
		verifyStorageCapability(context, "not-a-capability", legacy),
		false,
	);
});
