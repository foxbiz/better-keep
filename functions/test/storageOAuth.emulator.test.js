const assert = require("node:assert/strict");
const { test, before, after } = require("node:test");
const { randomBytes } = require("node:crypto");
// Never reuse a running personal emulator or production credentials.
assert.match(
	process.env.FIRESTORE_EMULATOR_HOST || "",
	/^(127\.0\.0\.1|localhost):[0-9]+$/,
);
process.env.GCLOUD_PROJECT = "demo-better-keep-security";
process.env.FUNCTIONS_EMULATOR = "true";
const { db, auth, app } = require("../lib/config");
const backend = require("../lib/storageConnectionBackend");
const logger = require("firebase-functions/logger");
const userIds = [];
const originalVerify = auth.verifyIdToken;
const originalFetch = global.fetch;
before(() => {
	auth.verifyIdToken = async (token) => ({ uid: token });
	global.fetch = async () => {
		throw new Error(
			"Provider requests are forbidden in the ciphertext backend",
		);
	};
});
after(async () => {
	auth.verifyIdToken = originalVerify;
	global.fetch = originalFetch;
	for (const uid of userIds)
		await db.recursiveDelete(db.collection("users").doc(uid));
	await app.delete();
});
async function fixture() {
	const uid = `ciphertext-test-${randomBytes(12).toString("hex")}`;
	userIds.push(uid);
	const user = db.collection("users").doc(uid);
	await user.set({ email: "test@example.invalid" });
	await user
		.collection("devices")
		.doc("test-device")
		.set({ status: "approved" });
	const capability = randomBytes(32).toString("base64url");
	const request = (data) => ({
		auth: { uid, token: {} },
		rawRequest: { get: () => `Bearer ${uid}` },
		data: { provider: "dropbox", deviceId: "test-device", capability, ...data },
	});
	const input = {
		libraryId: "a".repeat(64),
		generation: 1,
		clientId: "public-client",
		encryptedCapability: randomBytes(100).toString("base64"),
		encryptedCredentials: randomBytes(100).toString("base64"),
	};
	return { uid, user, capability, request, input };
}
test("ciphertext round trip is capability protected and rejects plaintext fields", async () => {
	const f = await fixture();
	await assert.rejects(
		backend.registerEncryptedStorageConnection.run(
			f.request({ ...f.input, refreshToken: "synthetic-private" }),
		),
		{ code: "invalid-argument" },
	);
	await backend.registerEncryptedStorageConnection.run(f.request(f.input));
	const privateData = (
		await f.user.collection("storage_credentials").doc("dropbox").get()
	).data();
	assert.equal(privateData.version, 2);
	assert.equal(privateData.encryptedCredentials, f.input.encryptedCredentials);
	assert.equal(
		JSON.stringify(privateData).includes("synthetic-private"),
		false,
	);
	const material = await backend.getEncryptedStorageCredentials.run(
		f.request({ generation: 1 }),
	);
	assert.equal(material.encryptedCredentials, f.input.encryptedCredentials);
	await assert.rejects(
		backend.getEncryptedStorageCredentials.run(
			f.request({
				generation: 1,
				capability: randomBytes(32).toString("base64url"),
			}),
		),
		{ code: "permission-denied" },
	);
	await assert.rejects(
		backend.getEncryptedStorageCredentials.run(f.request({ generation: 2 })),
		{ code: "permission-denied" },
	);
});
test("refresh transactions serialize competitors; disconnect fences late publication", async () => {
	const f = await fixture();
	await backend.registerEncryptedStorageConnection.run(f.request(f.input));
	const results = await Promise.allSettled(
		[1, 2].map(() =>
			backend.acquireStorageRefreshLease.run(
				f.request({ generation: 1, revision: 1 }),
			),
		),
	);
	assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
	const lease = results.find((r) => r.status === "fulfilled").value;
	await backend.beginStorageDisconnect.run(f.request({}));
	await assert.rejects(
		backend.finishStorageRefresh.run(
			f.request({
				generation: 1,
				revision: 1,
				leaseId: lease.leaseId,
				fence: lease.fence,
				encryptedCredentials: randomBytes(100).toString("base64"),
			}),
		),
		{ code: "permission-denied" },
	);
	await backend.disconnectStorageConnection.run(f.request({}));
	assert.equal(
		(await f.user.collection("storage_credentials").doc("dropbox").get()).data()
			.encryptedCredentials,
		null,
	);
});
test("deleted accounts, scheduled deletion and unapproved devices cannot use ciphertext endpoints", async () => {
	for (const mutation of ["deleted", "scheduled", "pending"]) {
		const f = await fixture();
		if (mutation === "deleted") await f.user.delete();
		if (mutation === "scheduled")
			await f.user.update({ scheduledDeletion: { date: "later" } });
		if (mutation === "pending")
			await f.user
				.collection("devices")
				.doc("test-device")
				.update({ status: "pending" });
		await assert.rejects(
			backend.registerEncryptedStorageConnection.run(f.request(f.input)),
			{ code: "permission-denied" },
		);
	}
});
test("stale auth and review sessions fail closed; diagnostics omit credentials", async (t) => {
	const f = await fixture();
	t.mock.method(auth, "verifyIdToken", async () => {
		throw Object.assign(new Error("private-provider-token"), {
			code: "auth/user-not-found",
		});
	});
	await assert.rejects(
		backend.registerEncryptedStorageConnection.run(f.request(f.input)),
		{ code: "unauthenticated" },
	);
	const entries = [];
	t.mock.method(logger, "warn", (message, fields) =>
		entries.push({ message, fields }),
	);
	await assert.rejects(
		backend.sanitizedStorageAction(async () => {
			throw new Error("private-provider-token");
		}),
		{ code: "unavailable" },
	);
	assert.equal(
		JSON.stringify(entries).includes("private-provider-token"),
		false,
	);
	const request = f.request(f.input);
	request.auth.token.appReview = true;
	await assert.rejects(
		backend.registerEncryptedStorageConnection.run(request),
		{ code: "permission-denied" },
	);
});
