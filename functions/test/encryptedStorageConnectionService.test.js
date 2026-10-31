const { test } = require("node:test");
const assert = require("node:assert/strict");
const { randomBytes } = require("node:crypto");
const {
	EncryptedStorageConnectionService,
} = require("../lib/encryptedStorageConnectionService");
const context = {
	uid: "user",
	provider: "google_drive",
	connectionId: "google_drive",
};
const capability = () => randomBytes(32).toString("base64url");
const ciphertext = () => randomBytes(100).toString("base64");
function setup() {
	let record = null;
	let now = 1000;
	const service = new EncryptedStorageConnectionService(
		{
			async transact(_context, mutate) {
				const result = mutate(record && structuredClone(record));
				if (result.next) record = structuredClone(result.next);
				return result.result;
			},
		},
		() => now,
	);
	const registration = {
		capability: capability(),
		encryptedCapability: ciphertext(),
		encryptedCredentials: ciphertext(),
		libraryId: "a".repeat(64),
		clientId: "public-client-id",
		generation: 1,
	};
	return {
		service,
		registration,
		record: () => record,
		advance: () => {
			now += 61000;
		},
	};
}
test("stores ciphertext only; registration is idempotent and generation fenced", async () => {
	const t = setup();
	const first = await t.service.register(context, t.registration);
	assert.equal(first.accountLabel, "");
	assert.equal(first.credentialVersion, 2);
	assert.deepEqual(await t.service.register(context, t.registration), first);
	await assert.rejects(
		t.service.register(context, {
			...t.registration,
			capability: capability(),
		}),
		/denied/,
	);
	await assert.rejects(
		t.service.read(
			{ ...context, uid: "attacker" },
			t.registration.capability,
			1,
		),
		/denied/,
	);
	assert.equal(
		(await t.service.read(context, t.registration.capability, 1))
			.encryptedCredentials,
		t.registration.encryptedCredentials,
	);
});
test("refresh lease serializes devices and persists rotated ciphertext without changing replica", async () => {
	const t = setup();
	await t.service.register(context, t.registration);
	const lease = await t.service.acquire(
		context,
		t.registration.capability,
		1,
		1,
	);
	await assert.rejects(
		t.service.acquire(context, t.registration.capability, 1, 1),
		/busy/,
	);
	const update = {
		generation: 1,
		revision: 1,
		leaseId: lease.leaseId,
		fence: lease.fence,
		encryptedCredentials: ciphertext(),
	};
	assert.equal(
		(await t.service.finish(context, t.registration.capability, update))
			.revision,
		2,
	);
	assert.equal(
		(await t.service.finish(context, t.registration.capability, update))
			.revision,
		2,
	);
	assert.equal(t.record().public.generation, 1);
	assert.equal(
		(await t.service.acquire(context, t.registration.capability, 1, 1)).status,
		"changed",
	);
});
test("expired and displaced leases cannot overwrite a newer refresh", async () => {
	const t = setup();
	await t.service.register(context, t.registration);
	const old = await t.service.acquire(context, t.registration.capability, 1, 1);
	t.advance();
	const update = {
		generation: 1,
		revision: 1,
		leaseId: old.leaseId,
		fence: old.fence,
		encryptedCredentials: ciphertext(),
	};
	await assert.rejects(
		t.service.finish(context, t.registration.capability, update),
		/denied/,
	);
	const fresh = await t.service.acquire(
		context,
		t.registration.capability,
		1,
		1,
	);
	await t.service.release(context, t.registration.capability, old.leaseId);
	assert.equal(t.record().lease.id, fresh.leaseId);
	await assert.rejects(
		t.service.finish(context, t.registration.capability, update),
		/denied/,
	);
});
test("pause, disconnect and reconnect fence refreshes; disconnect removes ciphertext", async () => {
	const t = setup();
	await t.service.register(context, t.registration);
	const lease = await t.service.acquire(
		context,
		t.registration.capability,
		1,
		1,
	);
	const update = {
		generation: 1,
		revision: 1,
		leaseId: lease.leaseId,
		fence: lease.fence,
		encryptedCredentials: ciphertext(),
	};
	await t.service.setEnabled(context, t.registration.capability, false);
	await assert.rejects(
		t.service.finish(context, t.registration.capability, update),
		/denied/,
	);
	await t.service.disconnect(context, t.registration.capability, true);
	await assert.rejects(
		t.service.acquire(context, t.registration.capability, 1, 1),
		/denied/,
	);
	await t.service.disconnect(context, t.registration.capability, false);
	assert.equal(t.record().encryptedCredentials, null);
	const replacement = {
		...t.registration,
		capability: capability(),
		previousCapability: t.registration.capability,
		encryptedCredentials: ciphertext(),
		generation: 2,
	};
	await t.service.register(context, replacement);
	await assert.rejects(
		t.service.finish(context, t.registration.capability, update),
		/denied/,
	);
});
test("fresh consent can replace legacy ciphertext without opening it", async () => {
	const input = {
		capability: capability(),
		encryptedCapability: ciphertext(),
		encryptedCredentials: ciphertext(),
		libraryId: "b".repeat(64),
		clientId: "public-client",
		generation: 4,
	};
	const { storageCapabilityHash } = require("../lib/storageConnectionSecurity");
	const previous = capability();
	let record = {
		public: { generation: 3, updatedAt: 1 },
		capabilityHash: storageCapabilityHash(context, previous),
		credentials: { intentionallyUnreadable: true },
	};
	const service = new EncryptedStorageConnectionService({
		async transact(_c, mutate) {
			const result = mutate(record);
			if (result.next) record = result.next;
			return result.result;
		},
	});
	await assert.rejects(
		service.read(context, previous, 3),
		/reconnect_required/,
	);
	await service.register(context, { ...input, previousCapability: previous });
	assert.equal(record.version, 2);
	assert.equal("credentials" in record, false);
});

test("legacy disconnect deletes vault ciphertext without decrypting it", async () => {
	const { storageCapabilityHash } = require("../lib/storageConnectionSecurity");
	const cap = capability();
	let record = {
		public: {
			generation: 3,
			updatedAt: 1,
			libraryId: "c".repeat(64),
			encryptedCapability: ciphertext(),
		},
		capabilityHash: storageCapabilityHash(context, cap),
		credentials: { unreadable: true },
	};
	const service = new EncryptedStorageConnectionService({
		async transact(_c, mutate) {
			const result = mutate(record);
			if (result.next) record = result.next;
			return result.result;
		},
	});
	await service.disconnect(context, cap, true);
	await service.disconnect(context, cap, false);
	assert.equal(record.encryptedCredentials, null);
	assert.equal("credentials" in record, false);
	assert.equal(record.public.state, "disconnected");
	assert.equal(record.public.generation, 3);
});

test("clear OTP is scoped, rate limited, attempt limited and single use", async () => {
	const t = setup();
	const c = { ...context, deviceId: "approved-device" };
	await t.service.register(c, t.registration);
	const otp = await t.service.requestClear(c, t.registration.capability);
	assert.equal("code" in t.record().clearChallenge, false);
	assert.match(t.record().clearChallenge.hash, /^[0-9a-f]{64}$/);
	await assert.rejects(
		t.service.requestClear(c, t.registration.capability),
		/busy/,
	);
	await assert.rejects(
		t.service.beginClear(
			{ ...c, provider: "dropbox", connectionId: "dropbox" },
			t.registration.capability,
			otp.requestId,
			otp.code,
		),
		/denied/,
	);
	for (let i = 0; i < 5; i++)
		await assert.rejects(
			t.service.beginClear(
				c,
				t.registration.capability,
				otp.requestId,
				"000000",
			),
			/denied/,
		);
	assert.equal(t.record().clearChallenge.attempts, 5);
	await assert.rejects(
		t.service.beginClear(c, t.registration.capability, otp.requestId, otp.code),
		/denied/,
	);
	assert.equal(t.record().public.state, "ready");
	t.advance();
	const retry = await t.service.requestClear(c, t.registration.capability);
	const op = await t.service.beginClear(
		c,
		t.registration.capability,
		retry.requestId,
		retry.code,
	);
	assert.equal(t.record().public.state, "clearing");
	assert.equal(t.record().public.enabled, false);
	assert.equal(t.record().clearChallenge, null);
	await assert.rejects(
		t.service.beginClear(
			c,
			t.registration.capability,
			retry.requestId,
			retry.code,
		),
		/denied/,
	);
	await assert.rejects(
		t.service.setEnabled(c, t.registration.capability, true),
		/reconnect_required/,
	);
	await assert.rejects(
		t.service.disconnect(c, t.registration.capability, true),
		/busy/,
	);
	await assert.rejects(
		t.service.register(c, {
			...t.registration,
			generation: 2,
			previousCapability: t.registration.capability,
		}),
		/busy/,
	);
	await assert.rejects(
		t.service.finishClear(
			{ ...c, deviceId: "other-device" },
			t.registration.capability,
			op.operationId,
		),
		/denied/,
	);
	await t.service.finishClear(c, t.registration.capability, op.operationId);
	assert.equal(t.record().public.enabled, false);
	assert.equal(t.record().public.state, "ready");
	assert.equal(t.record().public.credentialVersion, 3);
	const epoch = t.record().public.storageEpoch;
	assert.match(epoch, /^[0-9a-f]{64}$/);
	assert.equal(t.record().public.libraryId, t.registration.libraryId);
	assert.equal(
		t.record().encryptedCredentials,
		t.registration.encryptedCredentials,
	);
	await t.service.finishClear(c, t.registration.capability, op.operationId);
	assert.equal(t.record().public.storageEpoch, epoch);
	await t.service.register(c, {
		...t.registration,
		generation: 2,
		previousCapability: t.registration.capability,
	});
	assert.equal(t.record().public.storageEpoch, epoch);
	assert.equal(t.record().public.credentialVersion, 3);
});

test("expired code cannot clear; refresh rotation finishes before OTP is consumed", async () => {
	const t = setup();
	const c = { ...context, deviceId: "device" };
	await t.service.register(c, t.registration);
	let otp = await t.service.requestClear(c, t.registration.capability);
	for (let i = 0; i < 10; i++) t.advance();
	await assert.rejects(
		t.service.beginClear(c, t.registration.capability, otp.requestId, otp.code),
		/denied/,
	);
	otp = await t.service.requestClear(c, t.registration.capability);
	const lease = await t.service.acquire(c, t.registration.capability, 1, 1);
	await assert.rejects(
		t.service.beginClear(c, t.registration.capability, otp.requestId, otp.code),
		/busy/,
	);
	assert.equal(t.record().clearChallenge.attempts, 0);
	await t.service.release(c, t.registration.capability, lease.leaseId);
	await t.service.beginClear(
		c,
		t.registration.capability,
		otp.requestId,
		otp.code,
	);
	await assert.rejects(
		t.service.acquire(
			{ ...c, deviceId: "other" },
			t.registration.capability,
			1,
			1,
		),
		/denied/,
	);
	const cleanupLease = await t.service.acquire(
		c,
		t.registration.capability,
		1,
		1,
	);
	assert.equal(cleanupLease.status, "acquired");
});

test("WebDAV accepts encrypted app credentials without an OAuth client ID", async () => {
 const t = setup();
 const dav = {...context, provider: "webdav", connectionId: "webdav"};
 const input = {...t.registration, clientId: ""};
 const connection = await t.service.register(dav, input);
 assert.equal(connection.provider, "webdav");
 assert.equal(connection.clientId, "");
 assert.equal((await t.service.read(dav, input.capability, 1)).encryptedCredentials, input.encryptedCredentials);
 await assert.rejects(t.service.read({...dav, provider: "nextcloud", connectionId: "nextcloud"}, input.capability, 1), /denied/);
});

test("token exchange binds token, capability, client, generation and live lease", async () => {
	const t = setup();
	t.registration.refreshBinding = "a".repeat(64);
	await t.service.register(context, t.registration);
	const lease = await t.service.acquire(
		context,
		t.registration.capability,
		1,
		1,
	);
	const input = {
		generation: 1,
		revision: 1,
		leaseId: lease.leaseId,
		fence: lease.fence,
		clientId: t.registration.clientId,
		binding: "a".repeat(64),
	};
	const before = t.record();
	for (const patch of [
		{ binding: "b".repeat(64) },
		{ clientId: "other" },
		{ generation: 2 },
		{ revision: 2 },
		{ leaseId: "other" },
		{ fence: 99 },
	])
		await assert.rejects(
			t.service.beginTokenRefresh(context, t.registration.capability, {
				...input,
				...patch,
			}),
			/denied/,
		);
	await assert.rejects(
		t.service.beginTokenRefresh(context, capability(), input),
		/denied/,
	);
	assert.deepEqual(t.record(), before);
	const exchangeId = await t.service.beginTokenRefresh(
		context,
		t.registration.capability,
		input,
	);
	await assert.rejects(
		t.service.beginTokenRefresh(context, t.registration.capability, input),
		/busy/,
	);
	const update = { ...input, encryptedCredentials: ciphertext() };
	await assert.rejects(
		t.service.finish(context, t.registration.capability, update),
		/busy/,
	);
	assert.equal(t.record().refreshBinding, "a".repeat(64));
	await t.service.completeTokenRefresh(
		context,
		t.registration.capability,
		input,
		exchangeId,
		"b".repeat(64),
	);
	// Provider rotation is pending until the ciphertext is committed.
	assert.equal(t.record().refreshBinding, "a".repeat(64));
	const committed = await t.service.finish(
		context,
		t.registration.capability,
		update,
	);
	assert.equal(t.record().refreshBinding, "b".repeat(64));
	assert.equal(t.record().encryptedCredentials, update.encryptedCredentials);
	assert.deepEqual(
		await t.service.finish(context, t.registration.capability, update),
		committed,
	);
	const next = await t.service.acquire(
		context,
		t.registration.capability,
		1,
		2,
	);
	const nextInput = {
		...input,
		revision: 2,
		leaseId: next.leaseId,
		fence: next.fence,
	};
	await assert.rejects(
		t.service.beginTokenRefresh(context, t.registration.capability, nextInput),
		/denied/,
	);
	await t.service.beginTokenRefresh(context, t.registration.capability, {
		...nextInput,
		binding: "b".repeat(64),
	});
});

test("unbound legacy exchange cannot bootstrap trust from a supplied token", async () => {
	const t = setup();
	await t.service.register(context, t.registration);
	const lease = await t.service.acquire(
		context,
		t.registration.capability,
		1,
		1,
	);
	await assert.rejects(
		t.service.beginTokenRefresh(context, t.registration.capability, {
			generation: 1,
			revision: 1,
			leaseId: lease.leaseId,
			fence: lease.fence,
			clientId: t.registration.clientId,
			binding: "a".repeat(64),
		}),
		/reconnect_required/,
	);
});

for (const invalidate of [
	"expiry",
	"disconnect",
	"reconnect",
	"release",
	"disable",
]) {
	test(`refresh completion cannot publish after ${invalidate}`, async () => {
		const t = setup();
		t.registration.refreshBinding = "a".repeat(64);
		await t.service.register(context, t.registration);
		const lease = await t.service.acquire(
			context,
			t.registration.capability,
			1,
			1,
		);
		const input = {
			generation: 1,
			revision: 1,
			leaseId: lease.leaseId,
			fence: lease.fence,
			clientId: t.registration.clientId,
			binding: "a".repeat(64),
		};
		const id = await t.service.beginTokenRefresh(
			context,
			t.registration.capability,
			input,
		);
		if (invalidate === "expiry") t.advance();
		if (invalidate === "disconnect")
			await t.service.disconnect(context, t.registration.capability, true);
		if (invalidate === "disable")
			await t.service.setEnabled(context, t.registration.capability, false);
		if (invalidate === "release")
			await t.service.release(
				context,
				t.registration.capability,
				lease.leaseId,
			);
		if (invalidate === "reconnect")
			await t.service.register(context, {
				...t.registration,
				generation: 2,
				previousCapability: t.registration.capability,
				capability: capability(),
				refreshBinding: "c".repeat(64),
			});
		const before = t.record();
		await assert.rejects(
			t.service.completeTokenRefresh(
				context,
				t.registration.capability,
				input,
				id,
				"b".repeat(64),
			),
			/denied/,
		);
		assert.deepEqual(t.record(), before);
	});
}
test("failed or lost refresh response never advances the committed fingerprint", async () => {
	const t = setup();
	t.registration.refreshBinding = "a".repeat(64);
	await t.service.register(context, t.registration);
	const lease = await t.service.acquire(
		context,
		t.registration.capability,
		1,
		1,
	);
	const input = {
		generation: 1,
		revision: 1,
		leaseId: lease.leaseId,
		fence: lease.fence,
		clientId: t.registration.clientId,
		binding: "a".repeat(64),
	};
	const id = await t.service.beginTokenRefresh(
		context,
		t.registration.capability,
		input,
	);
	await t.service.completeTokenRefresh(
		context,
		t.registration.capability,
		input,
		id,
		"b".repeat(64),
	);
	await assert.rejects(
		t.service.completeTokenRefresh(
			context,
			t.registration.capability,
			input,
			id,
			"c".repeat(64),
		),
		/denied/,
	);
	await t.service.release(context, t.registration.capability, lease.leaseId);
	assert.equal(t.record().refreshBinding, "a".repeat(64));
	assert.equal(
		t.record().encryptedCredentials,
		t.registration.encryptedCredentials,
	);
});
