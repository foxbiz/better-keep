const assert = require("node:assert/strict");
const { test, beforeEach, afterEach, mock } = require("node:test");
const { randomBytes } = require("node:crypto");

// Exercise real callable/service boundaries with an in-memory transactional
// repository. No emulator accounts, secrets, provider calls or network I/O.
process.env.GCLOUD_PROJECT = "demo-storage-binding";
process.env.FUNCTIONS_EMULATOR = "true";
process.env.EMULATOR_WEB_ORIGIN = "https://example.test";
process.env.GOOGLE_DRIVE_CLIENT_ID = "fixture-client";
const config = require("../lib/config");
const connections = require("../lib/storageConnectionBackend");
const exchange = require("../lib/storageTokenExchangeBackend");
const logger = require("firebase-functions/logger");
let records, logs, fetches, respond, tail;
const request = (uid, data) => ({
	auth: { uid, token: {} },
	data: { provider: "google_drive", deviceId: "device", ...data },
	rawRequest: {
		get: (name) => (name === "authorization" ? `Bearer ${uid}` : undefined),
	},
});
const call = (endpoint, uid, data) => endpoint.run(request(uid, data));
const snapshot = (path) => ({
	exists: records.has(path),
	data: () => structuredClone(records.get(path)),
});
const ref = (path) => ({
	path,
	get: async () => snapshot(path),
	collection: (name) => ({ doc: (id) => ref(`${path}/${name}/${id}`) }),
});
const record = (uid) =>
	records.get(`users/${uid}/storage_credentials/google_drive`);
const cipher = () => randomBytes(100).toString("base64");
beforeEach(() => {
	records = new Map();
	logs = [];
	fetches = 0;
	tail = Promise.resolve();
	for (const uid of ["alice", "bob"]) {
		records.set(`users/${uid}`, {});
		records.set(`users/${uid}/devices/device`, { status: "approved" });
	}
	mock.method(config.googleDriveClientSecret, "value", () => "fixture-secret");
	mock.method(config.auth, "verifyIdToken", async (uid) => ({ uid }));
	mock.method(logger, "warn", (...args) => logs.push(args));
	mock.method(config.db, "collection", (name) => ({
		doc: (id) => ref(`${name}/${id}`),
	}));
	mock.method(config.db, "runTransaction", (action) => {
		const run = tail.then(async () => {
			const writes = new Map();
			const result = await action({
				get: async (r) => snapshot(r.path),
				set: (r, value) => writes.set(r.path, structuredClone(value)),
			});
			for (const [path, value] of writes) records.set(path, value);
			return result;
		});
		tail = run.catch(() => {});
		return run;
	});
	respond = async (form) => ({
		access_token: "private-access",
		refresh_token: `private-refresh-${form.get("code") ?? "rotated"}`,
		expires_in: 3600,
		token_type: "Bearer",
	});
	mock.method(globalThis, "fetch", async (_url, options) => {
		fetches++;
		return new Response(JSON.stringify(await respond(options.body)));
	});
});
afterEach(() => mock.restoreAll());
async function consent(uid) {
	return call(exchange.exchangeStorageOAuthToken, uid, {
		operation: "code",
		clientId: "fixture-client",
		code: uid,
		verifier: "v".repeat(43),
		redirectUri: "https://example.test/oauth/storage/callback",
	});
}
async function connect(uid) {
	const grant = await consent(uid);
	const registration = {
		clientId: "fixture-client",
		generation: 1,
		capability: randomBytes(32).toString("base64url"),
		encryptedCapability: cipher(),
		encryptedCredentials: cipher(),
		libraryId: "a".repeat(64),
		exchangeProof: grant.exchangeProof,
	};
	await call(connections.registerEncryptedStorageConnection, uid, registration);
	return {
		uid,
		grant,
		registration,
		base: { capability: registration.capability, generation: 1 },
	};
}
async function lease(c) {
	const value = await call(connections.acquireStorageRefreshLease, c.uid, {
		...c.base,
		revision: record(c.uid).revision,
	});
	return {
		...c.base,
		revision: value.revision,
		leaseId: value.leaseId,
		fence: value.fence,
	};
}
const refresh = (c, l, token = c.grant.refreshToken) =>
	call(exchange.exchangeStorageOAuthToken, c.uid, {
		...l,
		operation: "refresh",
		clientId: "fixture-client",
		refreshToken: token,
	});

test("stolen refresh token and stolen receipt cannot cross account boundaries", async () => {
	const alice = await connect("alice"),
		bob = await connect("bob");
	const l = await lease(bob),
		before = structuredClone([...records]);
	const count = fetches;
	await assert.rejects(refresh(bob, l, alice.grant.refreshToken), {
		code: "permission-denied",
	});
	assert.equal(fetches, count);
	assert.deepEqual([...records], before);
	await assert.rejects(
		call(connections.registerEncryptedStorageConnection, "bob", {
			...bob.registration,
			exchangeProof: alice.grant.exchangeProof,
		}),
		{ code: "permission-denied" },
	);
	assert.deepEqual([...records], before);
});

test("registration requires a verified receipt and rejects caller-written fingerprints", async () => {
	const c = await connect("alice");
	const base = { ...c.registration };
	delete base.exchangeProof;
	await assert.rejects(
		call(connections.registerEncryptedStorageConnection, "alice", base),
		{ code: "failed-precondition" },
	);
	await assert.rejects(
		call(connections.registerEncryptedStorageConnection, "alice", {
			...base,
			refreshBinding: "a".repeat(64),
		}),
		{ code: "invalid-argument" },
	);
	await assert.rejects(
		call(connections.registerEncryptedStorageConnection, "alice", {
			...c.registration,
			exchangeProof: "forged",
		}),
		{ code: "permission-denied" },
	);
	await assert.rejects(
		call(connections.registerEncryptedStorageConnection, "alice", {
			...c.registration,
			generation: 2,
			previousCapability: c.registration.capability,
		}),
		{ code: "permission-denied" },
	);
	assert.equal(record("alice").public.generation, 1);
	// Exact retry after a lost registration response remains idempotent.
	await call(
		connections.registerEncryptedStorageConnection,
		"alice",
		c.registration,
	);
	assert.equal(record("alice").revision, 1);
});

test("rotated fingerprint commits with ciphertext; another approved device can refresh it", async () => {
	const c = await connect("alice"),
		l = await lease(c);
	const old = record("alice").refreshBinding;
	const fresh = await refresh(c, l);
	assert.equal(record("alice").refreshBinding, old);
	const update = { ...l, encryptedCredentials: cipher() };
	await call(connections.finishStorageRefresh, "alice", update);
	assert.notEqual(record("alice").refreshBinding, old);
	assert.equal(
		record("alice").encryptedCredentials,
		update.encryptedCredentials,
	);
	await call(connections.finishStorageRefresh, "alice", update);
	assert.equal(record("alice").revision, 2);
	const next = await lease(c);
	await assert.rejects(refresh(c, next), { code: "permission-denied" });
	records.set("users/alice/devices/second", { status: "approved" });
	await call(exchange.exchangeStorageOAuthToken, "alice", {
		...next,
		deviceId: "second",
		operation: "refresh",
		clientId: "fixture-client",
		refreshToken: fresh.refreshToken,
	});
	assert.doesNotMatch(
		JSON.stringify([...records]),
		/private-refresh|private-access|fixture-secret/,
	);
	assert.doesNotMatch(
		JSON.stringify(logs),
		/private-refresh|private-access|fixture-secret/,
	);
});

test("concurrent requests with the same lease perform exactly one provider refresh", async () => {
	const c = await connect("alice"),
		l = await lease(c),
		before = fetches;
	const results = await Promise.allSettled([refresh(c, l), refresh(c, l)]);
	assert.equal(results.filter((r) => r.status === "fulfilled").length, 1);
	assert.equal(
		results.find((r) => r.status === "rejected").reason.code,
		"aborted",
	);
	assert.equal(fetches, before + 1);
});

test("disconnect during provider exchange prevents response delivery and binding commit", async () => {
	const c = await connect("alice"),
		l = await lease(c),
		old = record("alice").refreshBinding;
	respond = async () => {
		await call(connections.beginStorageDisconnect, "alice", {
			capability: c.base.capability,
		});
		return {
			access_token: "private-access",
			refresh_token: "private-refresh-late",
			expires_in: 3600,
			token_type: "Bearer",
		};
	};
	await assert.rejects(refresh(c, l), { code: "permission-denied" });
	assert.equal(record("alice").refreshBinding, old);
	assert.equal(record("alice").public.state, "disconnecting");
	assert.equal(record("alice").lease, null);
});

test("direct client-side provider grants still register and commit without exchange bindings", async () => {
	const base = {
		provider: "dropbox",
		clientId: "dropbox-public-client",
		generation: 1,
		capability: randomBytes(32).toString("base64url"),
	};
	await call(connections.registerEncryptedStorageConnection, "alice", {
		...base,
		libraryId: "a".repeat(64),
		encryptedCapability: cipher(),
		encryptedCredentials: cipher(),
	});
	const l = await call(connections.acquireStorageRefreshLease, "alice", {
		provider: "dropbox",
		capability: base.capability,
		generation: 1,
		revision: 1,
	});
	await call(connections.finishStorageRefresh, "alice", {
		provider: "dropbox",
		capability: base.capability,
		generation: 1,
		revision: 1,
		leaseId: l.leaseId,
		fence: l.fence,
		encryptedCredentials: cipher(),
	});
	const stored = records.get("users/alice/storage_credentials/dropbox");
	assert.equal(stored.revision, 2);
	assert.equal(stored.refreshBinding, undefined);
});

test("non-rotating refresh retains the binding across repeated ciphertext commits", async () => {
	const c = await connect("alice"),
		old = record("alice").refreshBinding;
	respond = async () => ({
		access_token: "private-access",
		expires_in: 3600,
		token_type: "Bearer",
	});
	for (let revision = 1; revision <= 2; revision++) {
		const l = await lease(c);
		const fresh = await refresh(c, l);
		assert.equal(fresh.refreshToken, undefined);
		await call(connections.finishStorageRefresh, c.uid, {
			...l,
			encryptedCredentials: cipher(),
		});
		assert.equal(record(c.uid).refreshBinding, old);
		assert.equal(record(c.uid).revision, revision + 1);
	}
});

test("failed provider response cannot commit and releasing its lease allows a safe retry", async () => {
	const c = await connect("alice"),
		l = await lease(c),
		old = record("alice").refreshBinding;
	const success = respond;
	respond = async () => {
		throw new Error("private-provider-network-error");
	};
	await assert.rejects(refresh(c, l), { code: "unavailable" });
	await assert.rejects(
		call(connections.finishStorageRefresh, c.uid, {
			...l,
			encryptedCredentials: cipher(),
		}),
		{ code: "aborted" },
	);
	assert.equal(record(c.uid).refreshBinding, old);
	assert.equal(record(c.uid).revision, 1);
	await call(connections.releaseStorageRefreshLease, c.uid, {
		capability: c.base.capability,
		leaseId: l.leaseId,
	});
	respond = success;
	const retry = await lease(c);
	await refresh(c, retry);
	await call(connections.finishStorageRefresh, c.uid, {
		...retry,
		encryptedCredentials: cipher(),
	});
	assert.equal(record(c.uid).revision, 2);
	assert.doesNotMatch(JSON.stringify(logs), /private-provider-network-error/);
});

test("device revocation while the provider responds blocks credentials and publication", async () => {
	const c = await connect("alice"),
		l = await lease(c),
		old = record("alice").refreshBinding;
	const success = respond;
	respond = async (form) => {
		records.set("users/alice/devices/device", { status: "revoked" });
		return success(form);
	};
	await assert.rejects(refresh(c, l), { code: "permission-denied" });
	assert.equal(record(c.uid).refreshBinding, old);
	assert.equal(record(c.uid).lease.exchange.nextBinding, null);
	await assert.rejects(
		call(connections.finishStorageRefresh, c.uid, {
			...l,
			encryptedCredentials: cipher(),
		}),
		{ code: "permission-denied" },
	);
});

test("reconnecting fences the old token, receipt and in-flight refresh", async () => {
	const c = await connect("alice"),
		l = await lease(c);
	const grant = await consent(c.uid);
	const replacement = {
		...c.registration,
		generation: 2,
		previousCapability: c.base.capability,
		capability: randomBytes(32).toString("base64url"),
		encryptedCredentials: cipher(),
		exchangeProof: grant.exchangeProof,
	};
	const success = respond;
	respond = async (form) => {
		await call(
			connections.registerEncryptedStorageConnection,
			c.uid,
			replacement,
		);
		return success(form);
	};
	await assert.rejects(refresh(c, l), { code: "permission-denied" });
	assert.equal(record(c.uid).public.generation, 2);
	assert.equal(
		record(c.uid).encryptedCredentials,
		replacement.encryptedCredentials,
	);
	await assert.rejects(
		call(connections.registerEncryptedStorageConnection, c.uid, c.registration),
		{ code: "permission-denied" },
	);
	respond = success;
	const next = {
		...c,
		grant,
		base: { capability: replacement.capability, generation: 2 },
	};
	await refresh(next, await lease(next));
});

test("secret rotation fails closed before contacting the provider", async () => {
	const c = await connect("alice"),
		l = await lease(c),
		count = fetches;
	config.googleDriveClientSecret.value = () => "replacement-fixture-secret";
	await assert.rejects(refresh(c, l), { code: "permission-denied" });
	await assert.rejects(
		call(connections.registerEncryptedStorageConnection, c.uid, c.registration),
		{ code: "permission-denied" },
	);
	assert.equal(fetches, count);
	assert.equal(record(c.uid).lease.exchange, undefined);
});
