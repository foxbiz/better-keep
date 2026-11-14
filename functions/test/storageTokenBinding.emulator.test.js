const assert = require("node:assert/strict");
const { test, before, after, mock } = require("node:test");
const { randomBytes } = require("node:crypto");

// Loopback test emulator and dedicated demo project only. Provider/auth/secret inputs
// are synthetic; Firestore transactions and callable/service code are real.
assert.match(
	process.env.FIRESTORE_EMULATOR_HOST || "",
	/^(127\.0\.0\.1|localhost):[0-9]+$/,
);
process.env.GCLOUD_PROJECT = "demo-storage-binding-transactions";
process.env.FUNCTIONS_EMULATOR = "true";
process.env.EMULATOR_WEB_ORIGIN = "https://example.test";
process.env.GOOGLE_DRIVE_CLIENT_ID = "fixture-client";
const config = require("../lib/config");
const connections = require("../lib/storageConnectionBackend");
const exchange = require("../lib/storageTokenExchangeBackend");
const users = [];
let refreshCalls = 0;
const cipher = () => randomBytes(100).toString("base64");
before(() => {
	mock.method(config.auth, "verifyIdToken", async (uid) => ({ uid }));
	mock.method(config.googleDriveClientSecret, "value", () => "fixture-secret");
	mock.method(globalThis, "fetch", async (_url, options) => {
		const refresh = options.body.get("grant_type") === "refresh_token";
		if (refresh) refreshCalls++;
		return new Response(
			JSON.stringify({
				access_token: "private-access",
				refresh_token: refresh ? "private-rotated" : "private-original",
				expires_in: 3600,
				token_type: "Bearer",
			}),
		);
	});
});
after(async () => {
	mock.restoreAll();
	for (const uid of users) {
		await config.db.recursiveDelete(config.db.collection("users").doc(uid));
		await config.db.collection("oauth_exchange_limits").doc(uid).delete();
	}
	await config.app.delete();
});
async function fixture() {
	const uid = `binding-${randomBytes(12).toString("hex")}`;
	users.push(uid);
	const user = config.db.collection("users").doc(uid);
	await user.set({});
	await user.collection("devices").doc("device").set({ status: "approved" });
	const call = (endpoint, data) =>
		endpoint.run({
			auth: { uid, token: {} },
			rawRequest: { get: () => `Bearer ${uid}` },
			data: { provider: "google_drive", deviceId: "device", ...data },
		});
	const grant = await call(exchange.exchangeStorageOAuthToken, {
		operation: "code",
		clientId: "fixture-client",
		code: "fixture-code",
		verifier: "v".repeat(43),
		redirectUri: "https://example.test/oauth/storage/callback",
	});
	const registration = {
		clientId: "fixture-client",
		generation: 1,
		capability: randomBytes(32).toString("base64url"),
		encryptedCapability: cipher(),
		encryptedCredentials: cipher(),
		libraryId: "a".repeat(64),
		exchangeProof: grant.exchangeProof,
	};
	const ref = user.collection("storage_credentials").doc("google_drive");
	const read = async () => (await ref.get()).data();
	return { call, registration, read, user };
}
test("real transactions serialize registration and refresh; fingerprint and ciphertext commit atomically", async () => {
	const f = await fixture();
	const results = await Promise.allSettled(
		[
			f.registration,
			{
				...f.registration,
				capability: randomBytes(32).toString("base64url"),
				encryptedCredentials: cipher(),
			},
		].map((r) =>
			f.call(connections.registerEncryptedStorageConnection, r).then(() => r),
		),
	);
	assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
	const winner = results.find((r) => r.status === "fulfilled").value;
	const base = { capability: winner.capability, generation: 1, revision: 1 };
	const lease = await f.call(connections.acquireStorageRefreshLease, base);
	const input = { ...base, leaseId: lease.leaseId, fence: lease.fence };
	const before = await f.read();
	const refresh = () =>
		f.call(exchange.exchangeStorageOAuthToken, {
			...input,
			operation: "refresh",
			clientId: "fixture-client",
			refreshToken: "private-original",
		});
	const count = refreshCalls;
	const competing = await Promise.allSettled([refresh(), refresh(), refresh()]);
	assert.equal(competing.filter((r) => r.status === "fulfilled").length, 1);
	assert.ok(
		competing
			.filter((r) => r.status === "rejected")
			.every((r) => r.reason.code === "aborted"),
	);
	assert.equal(refreshCalls, count + 1);
	const pending = await f.read();
	assert.equal(pending.refreshBinding, before.refreshBinding);
	assert.equal(pending.encryptedCredentials, winner.encryptedCredentials);
	assert.notEqual(pending.lease.exchange.nextBinding, before.refreshBinding);
	const update = { ...input, encryptedCredentials: cipher() };
	await Promise.all(
		[1, 2].map(() => f.call(connections.finishStorageRefresh, update)),
	);
	const committed = await f.read();
	assert.equal(committed.revision, 2);
	assert.equal(committed.refreshBinding, pending.lease.exchange.nextBinding);
	assert.equal(committed.encryptedCredentials, update.encryptedCredentials);
	assert.equal(committed.lease, null);
	const publicData = (
		await f.user.collection("storage_connections").doc("google_drive").get()
	).data();
	assert.equal(publicData.refreshBinding, undefined);
	assert.equal(publicData.lease, undefined);
	assert.doesNotMatch(
		JSON.stringify([committed, publicData]),
		/private-original|private-rotated|private-access|fixture-secret/,
	);
});

test("legacy unbound connection cannot use the exchange and can recover through fresh consent", async () => {
	const f = await fixture();
	// Model an existing record, written only to this isolated demo fixture.
	await f.call(connections.registerEncryptedStorageConnection, f.registration);
	await f.user
		.collection("storage_credentials")
		.doc("google_drive")
		.update({
			refreshBinding: require("firebase-admin/firestore").FieldValue.delete(),
		});
	const base = {
		capability: f.registration.capability,
		generation: 1,
		revision: 1,
	};
	const lease = await f.call(connections.acquireStorageRefreshLease, base);
	const count = refreshCalls;
	await assert.rejects(
		f.call(exchange.exchangeStorageOAuthToken, {
			...base,
			leaseId: lease.leaseId,
			fence: lease.fence,
			operation: "refresh",
			clientId: "fixture-client",
			refreshToken: "private-original",
		}),
		{ code: "failed-precondition" },
	);
	assert.equal(refreshCalls, count);
	const grant = await f.call(exchange.exchangeStorageOAuthToken, {
		operation: "code",
		clientId: "fixture-client",
		code: "fixture-code",
		verifier: "v".repeat(43),
		redirectUri: "https://example.test/oauth/storage/callback",
	});
	await f.call(connections.registerEncryptedStorageConnection, {
		...f.registration,
		generation: 2,
		previousCapability: base.capability,
		capability: randomBytes(32).toString("base64url"),
		exchangeProof: grant.exchangeProof,
	});
	const restored = await f.read();
	assert.equal(restored.public.generation, 2);
	assert.match(restored.refreshBinding, /^[a-f0-9]{64}$/);
	assert.equal(restored.lease, null);
});
