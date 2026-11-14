const assert = require("node:assert/strict");
const { test, beforeEach, afterEach, mock } = require("node:test");
const { HttpsError } = require("firebase-functions/v2/https");

// Test process only: all persistence, authorization and HTTP boundaries are
// mocked. Never reads emulator accounts, provider credentials or real tokens.
process.env.GCLOUD_PROJECT = "demo-storage-exchange";
process.env.FUNCTIONS_EMULATOR = "true";
process.env.EMULATOR_WEB_ORIGIN = "https://example.test";
process.env.GOOGLE_DRIVE_CLIENT_ID = "fixture-client";
const config = require("../lib/config");
const sessions = require("../lib/storageConnectionBackend");
const logger = require("firebase-functions/logger");
const backend = require("../lib/storageTokenExchangeBackend");
const {
	storageRefreshBinding,
	verifyStorageGrant,
} = require("../lib/storageTokenBinding");
const context = {
	uid: "qa",
	deviceId: "device",
	provider: "google_drive",
	connectionId: "google_drive",
};
const fingerprint = (token) =>
	storageRefreshBinding("fixture-secret", context, "fixture-client", 1, token);
const redirectUri = "https://example.test/oauth/storage/callback";
const request = (data = {}) => ({
	auth: { uid: "qa", token: {} },
	data: {
		provider: "google_drive",
		deviceId: "device",
		operation: "code",
		clientId: "fixture-client",
		code: "fixture-code",
		verifier: "v".repeat(43),
		redirectUri,
		...data,
	},
});
const refresh = () =>
	request({
		operation: "refresh",
		refreshToken: "fixture-refresh",
		capability: "fixture-capability",
		generation: 1,
		revision: 2,
		fence: 3,
		leaseId: "lease",
	});
let events,
	writes,
	logs,
	count,
	rejectSessionAt,
	rejectLeaseAt,
	sessionCalls,
	leaseCalls,
	fetchCalls;
beforeEach(() => {
	events = [];
	writes = [];
	logs = [];
	count = 0;
	sessionCalls = leaseCalls = fetchCalls = 0;
	rejectSessionAt = rejectLeaseAt = Infinity;
	mock.method(config.googleDriveClientSecret, "value", () => "fixture-secret");
	mock.method(logger, "warn", (...args) => logs.push(args));
	mock.method(sessions, "requireStorageSession", async () => {
		events.push("session");
		if (++sessionCalls === rejectSessionAt)
			throw new HttpsError("permission-denied", "Session revoked");
		return {
			uid: "qa",
			deviceId: "device",
			provider: "google_drive",
			connectionId: "google_drive",
		};
	});
	mock.method(
		sessions,
		"beginStorageTokenRefresh",
		async (context, capability, lease) => {
			events.push("lease");
			assert.equal(context.uid, "qa");
			assert.equal(capability, "fixture-capability");
			assert.deepEqual(lease, {
				generation: 1,
				revision: 2,
				fence: 3,
				leaseId: "lease",
				clientId: "fixture-client",
				binding: fingerprint("fixture-refresh"),
			});
			if (++leaseCalls === rejectLeaseAt)
				throw new HttpsError("permission-denied", "Lease changed");
			return "exchange-id";
		},
	);
	mock.method(sessions, "storageTokenExchangeGeneration", async () => 1);
	mock.method(
		sessions,
		"completeStorageTokenRefresh",
		async (ctx, capability, lease, exchangeId, binding) => {
			events.push("lease");
			assert.equal(ctx.uid, "qa");
			assert.equal(capability, "fixture-capability");
			assert.equal(exchangeId, "exchange-id");
			assert.equal(lease.binding, fingerprint("fixture-refresh"));
			assert.equal(binding, fingerprint("fixture-rotated"));
			if (++leaseCalls === rejectLeaseAt)
				throw new HttpsError("permission-denied", "Lease changed");
		},
	);

	mock.method(config.db, "collection", (name) => {
		assert.equal(name, "oauth_exchange_limits");
		return {
			doc: (uid) => {
				assert.equal(uid, "qa");
				return "budget-ref";
			},
		};
	});
	mock.method(config.db, "runTransaction", async (action) =>
		action({
			get: async (ref) => {
				assert.equal(ref, "budget-ref");
				return { data: () => ({ startedAt: Date.now(), count }) };
			},
			set: (ref, data) => {
				assert.equal(ref, "budget-ref");
				count = data.count;
				writes.push(data);
				events.push("budget");
			},
		}),
	);
	mock.method(globalThis, "fetch", async (url, options) => {
		fetchCalls++;
		events.push("fetch");
		assert.equal(String(url), "https://oauth2.googleapis.com/token");
		assert.equal(options.redirect, "error");
		assert.equal(options.body.get("client_id"), "fixture-client");
		assert.equal(options.body.get("client_secret"), "fixture-secret");
		return new Response(
			JSON.stringify({
				access_token: "fixture-access",
				refresh_token: "fixture-rotated",
				expires_in: 3600,
				token_type: "Bearer",
			}),
		);
	});
});
afterEach(() => mock.restoreAll());

test("prepare authenticates and returns only public configuration", async () => {
	assert.deepEqual(await backend.prepareStorageTokenExchange.run(request()), {
		clientId: "fixture-client",
		redirectUri,
	});
	assert.deepEqual(events, ["session"]);
	assert.equal(fetchCalls, 0);
	assert.deepEqual(writes, []);
});
for (const operation of ["prepare", "code", "refresh"]) {
	test(`${operation} rejects an unapproved session before exchange or persistence`, async () => {
		rejectSessionAt = 1;
		const callable =
			operation === "prepare"
				? backend.prepareStorageTokenExchange
				: backend.exchangeStorageOAuthToken;
		await assert.rejects(
			callable.run(operation === "refresh" ? refresh() : request()),
			{ code: "permission-denied" },
		);
		assert.equal(fetchCalls, 0);
		assert.deepEqual(writes, []);
	});
}
test("code exchange rechecks the session and persists only budget metadata", async () => {
	const result = await backend.exchangeStorageOAuthToken.run(request());
	assert.equal(result.accessToken, "fixture-access");
	assert.equal(result.refreshToken, "fixture-rotated");
	assert.equal(
		verifyStorageGrant(
			"fixture-secret",
			context,
			"fixture-client",
			1,
			result.exchangeProof,
		),
		fingerprint("fixture-rotated"),
	);
	assert.deepEqual(events, ["session", "budget", "fetch", "session"]);
	assert.deepEqual(Object.keys(writes[0]).sort(), ["count", "startedAt"]);
	assert.doesNotMatch(
		JSON.stringify({ writes, logs }),
		/fixture-(access|refresh|rotated|secret|code)/,
	);
});
test("refresh validates the exact lease both before and after exchange", async () => {
	await backend.exchangeStorageOAuthToken.run(refresh());
	assert.deepEqual(events, [
		"session",
		"lease",
		"budget",
		"fetch",
		"session",
		"lease",
	]);
});
for (const boundary of ["session", "lease"]) {
	test(`revoked ${boundary} during exchange prevents token delivery`, async () => {
		if (boundary === "session") rejectSessionAt = 2;
		else rejectLeaseAt = 2;
		await assert.rejects(backend.exchangeStorageOAuthToken.run(refresh()), {
			code: "permission-denied",
		});
		assert.equal(fetchCalls, 1);
		assert.doesNotMatch(
			JSON.stringify({ writes, logs }),
			/fixture-(access|refresh|rotated|secret|code)/,
		);
	});
}
test("stale refresh lease is rejected before consuming budget or contacting Google", async () => {
	rejectLeaseAt = 1;
	await assert.rejects(backend.exchangeStorageOAuthToken.run(refresh()), {
		code: "permission-denied",
	});
	assert.equal(fetchCalls, 0);
	assert.deepEqual(writes, []);
});
for (const data of [
	{ provider: "unknown" },
	{ clientId: "other-client" },
	{ redirectUri: "https://attacker.test/callback" },
	{ tokenEndpoint: "https://attacker.test" },
]) {
	test(`invalid exchange input fails without contacting any provider: ${Object.keys(data)[0]}`, async () => {
		await assert.rejects(backend.exchangeStorageOAuthToken.run(request(data)), {
			code: "invalid-argument",
		});
		assert.equal(fetchCalls, 0);
	});
}
test("missing refresh lease fails without exchanging", async () => {
	const input = refresh();
	delete input.data.leaseId;
	await assert.rejects(backend.exchangeStorageOAuthToken.run(input), {
		code: "invalid-argument",
	});
	assert.equal(fetchCalls, 0);
	assert.deepEqual(writes, []);
});
test("per-user budget prevents a 21st exchange", async () => {
	count = 20;
	await assert.rejects(backend.exchangeStorageOAuthToken.run(request()), {
		code: "resource-exhausted",
	});
	assert.equal(fetchCalls, 0);
	assert.deepEqual(writes, []);
});
test("unexpected provider errors do not expose response data", async () => {
	mock.method(globalThis, "fetch", async () => {
		throw new Error("fixture-refresh fixture-secret");
	});
	await assert.rejects(
		backend.exchangeStorageOAuthToken.run(request()),
		(error) => {
			assert.equal(error.code, "unavailable");
			assert.doesNotMatch(
				JSON.stringify(error),
				/fixture-refresh|fixture-secret/,
			);
			return true;
		},
	);
	assert.doesNotMatch(JSON.stringify(logs), /fixture-refresh|fixture-secret/);
});

for (const reason of ["denied", "reconnect_required", "busy"]) {
	test(`token binding rejection (${reason}) prevents provider call and budget consumption`, async () => {
		const {
			StorageConnectionError,
		} = require("../lib/storageConnectionSecurity");
		mock.method(sessions, "beginStorageTokenRefresh", async () => {
			throw new StorageConnectionError(reason);
		});
		await assert.rejects(backend.exchangeStorageOAuthToken.run(refresh()));
		assert.equal(fetchCalls, 0);
		assert.deepEqual(writes, []);
	});
}
test("connection replacement during code exchange prevents receipt delivery", async () => {
	let checks = 0;
	mock.method(sessions, "storageTokenExchangeGeneration", async () => ++checks);
	await assert.rejects(backend.exchangeStorageOAuthToken.run(request()), {
		code: "permission-denied",
	});
	assert.equal(fetchCalls, 1);
});
test("non-rotating response preserves the current token fingerprint", async () => {
	mock.method(
		globalThis,
		"fetch",
		async () =>
			new Response(
				JSON.stringify({
					access_token: "fixture-access",
					expires_in: 3600,
					token_type: "Bearer",
				}),
			),
	);
	mock.method(
		sessions,
		"completeStorageTokenRefresh",
		async (_ctx, _cap, _lease, _id, binding) => {
			assert.equal(binding, fingerprint("fixture-refresh"));
		},
	);
	const result = await backend.exchangeStorageOAuthToken.run(refresh());
	assert.equal(result.refreshToken, undefined);
});
