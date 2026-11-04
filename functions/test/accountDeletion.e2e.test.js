const assert = require("node:assert/strict");
const { test, before, beforeEach, after } = require("node:test");
const { randomUUID } = require("node:crypto");
const http = require("node:http");
for (const name of [
	"FIRESTORE_EMULATOR_HOST",
	"FIREBASE_AUTH_EMULATOR_HOST",
	"FIREBASE_STORAGE_EMULATOR_HOST",
])
	assert.match(
		process.env[name] || "",
		/^(127\.0\.0\.1|localhost):\d+$/,
		`${name} must be local`,
	);
process.env.GCLOUD_PROJECT = "demo-better-keep-deletion";
process.env.FUNCTIONS_EMULATOR = "true";
process.env.TRIAL_ENABLED = "false";
process.env.FIREBASE_CONFIG = JSON.stringify({
	projectId: "demo-better-keep-deletion",
	storageBucket: "demo-better-keep-deletion.appspot.com",
});
const express = require("express");
const { Timestamp } = require("firebase-admin/firestore");
const { app, db, auth, storage } = require("../lib/config");
const lifecycle = require("../lib/accountDeletionLifecycle");
const emails = [];
// No SMTP is used. The complete rendered email is captured only in test memory.
require("../lib/utils").sendEmail = async (mail) => {
	emails.push(mail);
	return "logged";
};
const routes = {};
for (const name of [
	"createCustomToken",
	"sendDeletionOtp",
	"verifyDeletionOtp",
	"scheduleAccountDeletion",
	"cancelScheduledDeletion",
	"processScheduledDeletions",
	"sendDeletionReminders",
])
	routes[name] = require(`../lib/exports/${name}`).default;
const signInHook = require("../lib/exports/grantTrialOnFirstSignIn").default;
let server, origin;
before(async () => {
	const web = express();
	web.use(express.json());
	for (const [name, handler] of Object.entries(routes))
		web.post(`/${name}`, handler);
	server = http.createServer(web);
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	origin = `http://127.0.0.1:${server.address().port}`;
});
// Tests deliberately mutate worker configuration; node:test runs them serially.
beforeEach(async () => {
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	await db.collection("accountDeletionWorker").doc("scan").delete();
});
after(async () => {
	await new Promise((resolve) => server.close(resolve));
	await app.delete();
});
async function call(name, token, data = {}) {
	const response = await fetch(`${origin}/${name}`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			...(token ? { Authorization: `Bearer ${token}` } : {}),
		},
		body: JSON.stringify({ data }),
	});
	const body = await response.json();
	return { status: response.status, ...body };
}
async function tick(name) {
	const response = await fetch(`${origin}/${name}`, {
		method: "POST",
		headers: { "X-CloudScheduler-JobName": `local-test-${name}` },
	});
	assert.equal(response.status, 200, await response.text());
}
async function fixture() {
	const uid = `e2e-${randomUUID()}`;
	const email = `${uid}@example.invalid`;
	const password = "Synthetic-only-password-42";
	await auth.createUser({ uid, email, password, emailVerified: true });
	const r = await fetch(
		`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=demo-key`,
		{
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ email, password, returnSecureToken: true }),
		},
	);
	const { idToken } = await r.json();
	assert.ok(idToken);
	const user = db.collection("users").doc(uid);
	await user.set({ displayName: "Synthetic user" });
	await user
		.collection("notes")
		.doc("retained-note")
		.set({ content: "Synthetic encrypted payload" });
	await user
		.collection("devices")
		.doc("secondary-device")
		.set({ status: "approved" });
	await storage
		.bucket()
		.file(`users/${uid}/attachment`)
		.save("Synthetic encrypted attachment");
	return { uid, email, token: idToken, user };
}
async function schedule(f, {completeRevocation = true} = {}) {
	assert.equal((await call("sendDeletionOtp", f.token)).status, 200);
	const otp = (
		await f.user.collection("otpVerification").doc("deletion").get()
	).data().otp;
	assert.equal(
		(
			await call("scheduleAccountDeletion", f.token, {
				otp,
				userId: "another-account",
			})
		).status,
		200,
	);
	const pending = (await f.user.get()).data().scheduledDeletion;
	assert.equal(pending.state, "revoking");
	if (!completeRevocation) return pending;
	const ref = db.collection("accountDeletionRequests").doc(pending.requestId);
	await require("../lib/exports/revokeScheduledDeletionSessions").default.run({params: {requestId: pending.requestId}, data: await ref.get()});
	return (await f.user.get()).data().scheduledDeletion;
}
async function drainTokens(f, s) {
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	await tick("processScheduledDeletions");
	assert.equal((await auth.getUser(f.uid)).disabled, true);
	assert.equal(
		(await f.user.collection("notes").doc("retained-note").get()).exists,
		true,
	);
	const proof = db.collection("accountDeletionRequests").doc(s.requestId);
	assert.ok((await proof.get()).data().authInvalidatedAt);
	// Advance ONLY this synthetic request past the token and lease waiting periods.
	await proof.update({
		authInvalidatedAt: Timestamp.fromMillis(
			Date.now() - lifecycle.DELETION_TOKEN_DRAIN_MS - 1000,
		),
	});
	await f.user.update({
		"scheduledDeletion.leaseUntil": Timestamp.fromMillis(0),
	});
}

async function age(f, s, days = 31) {
	// Time travel affects only synthetic emulator fixtures and their server-owned proof.
	const scheduledAt = Timestamp.fromMillis(Date.now() - days * 86400000);
	const deleteAt = Timestamp.fromMillis(
		scheduledAt.toMillis() + lifecycle.DELETION_GRACE_MS,
	);
	const reminderAt = Timestamp.fromMillis(deleteAt.toMillis() - 86400000);
	await f.user.update({
		"scheduledDeletion.scheduledAt": scheduledAt,
		"scheduledDeletion.deleteAt": deleteAt,
		"scheduledDeletion.reminderAt": reminderAt,
	});
	await db
		.collection("accountDeletionRequests")
		.doc(s.requestId)
		.update({ requestedAt: scheduledAt, deleteAt });
	const response = await fetch(
		`http://${process.env.FIREBASE_AUTH_EMULATOR_HOST}/identitytoolkit.googleapis.com/v1/projects/demo-better-keep-deletion/accounts:update`,
		{
			method: "POST",
			headers: {
				"Content-Type": "application/json",
				Authorization: "Bearer owner",
			},
			body: JSON.stringify({
				localId: f.uid,
				lastLoginAt: String(scheduledAt.toMillis() - 1000),
			}),
		},
	);
	assert.equal(response.status, 200, await response.text());
	assert.equal(
		Date.parse((await auth.getUser(f.uid)).metadata.lastSignInTime),
		Math.floor((scheduledAt.toMillis() - 1000) / 1000) * 1000,
	);
}

test("HTTP authentication and OTP are required; scheduling preserves all devices and data", async () => {
	assert.equal(
		(await call("scheduleAccountDeletion", null, { otp: "123456" })).status,
		401,
	);
	const f = await fixture();
	assert.equal(
		(await call("scheduleAccountDeletion", f.token, {})).status,
		400,
	);
	const s = await schedule(f);
	assert.equal(s.version, 2);
	assert.equal(
		(await f.user.collection("devices").doc("secondary-device").get()).exists,
		true,
	);
	assert.equal(
		(await f.user.collection("notes").doc("retained-note").get()).exists,
		true,
	);
	assert.equal(
		(await storage.bucket().file(`users/${f.uid}/attachment`).exists())[0],
		true,
	);
	assert.equal(
		(await db.collection("users").doc("another-account").get()).exists,
		false,
	);
	assert.ok(
		emails.some((m) => m.to === f.email && m.subject.includes("Scheduled")),
	);
});

test("native password, Google and Apple sign-in hooks cancel before app initialization", async () => {
	for (const provider of ["password", "google.com", "apple.com"]) {
		const f = await fixture();
		const s = await schedule(f);
		await signInHook.run({
			eventId: randomUUID(),
			eventType: "providers/cloud.auth/eventTypes/user.beforeSignIn",
			data: {
				uid: f.uid,
				email: f.email,
				providerData: [{ providerId: provider }],
			},
			additionalUserInfo: { providerId: provider, isNewUser: false },
		});
		assert.equal((await f.user.get()).data().scheduledDeletion, undefined);
		assert.equal(
			(
				await db.collection("accountDeletionRequests").doc(s.requestId).get()
			).data().state,
			"cancelled",
		);
		assert.equal(
			(await f.user.collection("notes").doc("retained-note").get()).exists,
			true,
		);
	}
});

test("custom OAuth completion cancels pending deletion before issuing the sign-in token", async () => {
	const {
		createOAuthCompletion,
		redeemOAuthCompletion,
	} = require("../lib/oauthCompletion");
	const {
		createOpaqueToken,
		createClientTransactionId,
		challengeForVerifier,
	} = require("../lib/oauthSession");
	for (const provider of ["facebook", "github", "twitter", "apple"]) {
		const f = await fixture();
		await schedule(f);
		const verifier = createOpaqueToken();
		const code = await createOAuthCompletion({
			uid: f.uid,
			provider,
			challenge: challengeForVerifier(verifier),
			clientTransactionId: createClientTransactionId(),
		});
		const token = await redeemOAuthCompletion({ code, verifier });
		assert.ok(token);
		assert.equal((await f.user.get()).data().scheduledDeletion, undefined);
	}
});

test("HTTP cancellation leaves notes intact and worker default is disabled", async () => {
	const f = await fixture();
	const s = await schedule(f);
	await age(f, s);
	delete process.env.ACCOUNT_DELETION_ENABLED;
	await tick("processScheduledDeletions");
	assert.equal((await f.user.get()).exists, true);
	// Fresh authentication via a custom token is unnecessary for the endpoint's owner check in this emulator.
	assert.equal((await call("cancelScheduledDeletion", f.token)).status, 200);
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	await tick("processScheduledDeletions");
	assert.equal(
		(await f.user.collection("notes").doc("retained-note").get()).exists,
		true,
	);
	assert.equal((await auth.getUser(f.uid)).uid, f.uid);
});

test("real handler deletes an eligible synthetic account completely and preserves unrelated/legacy users", async () => {
	const f = await fixture();
	const s = await schedule(f);
	await age(f, s);
	const shareRef = db.collection("shares").doc(`share-${f.uid}`);
	await shareRef.set({ owner_uid: f.uid, status: "active" });
	await shareRef.collection("views").doc("one").set({ count: 1 });
	await db
		.collection("adminUsers")
		.doc(f.uid)
		.collection("nested")
		.doc("one")
		.set({ value: true });
	await storage
		.bucket()
		.file(`shares/${f.uid}/shared/attachments/file`)
		.save("synthetic");
	await drainTokens(f, s);
	const unrelated = await fixture();
	const legacy = await fixture();
	await legacy.user.update({
		scheduledDeletion: { deleteAt: Timestamp.fromMillis(0) },
	});
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	await tick("processScheduledDeletions");
	assert.equal((await f.user.get()).exists, false);
	assert.equal((await f.user.collection("notes").get()).empty, true);
	assert.equal(
		(await storage.bucket().file(`users/${f.uid}/attachment`).exists())[0],
		false,
	);
	await assert.rejects(auth.getUser(f.uid), { code: "auth/user-not-found" });
	assert.equal((await shareRef.get()).exists, false);
	assert.equal((await shareRef.collection("views").get()).empty, true);
	assert.equal(
		(await db.collection("adminUsers").doc(f.uid).collection("nested").get())
			.empty,
		true,
	);
	assert.equal(
		(
			await storage
				.bucket()
				.file(`shares/${f.uid}/shared/attachments/file`)
				.exists()
		)[0],
		false,
	);
	assert.equal(
		(
			await db.collection("accountDeletionRequests").doc(s.requestId).get()
		).data().state,
		"completed",
	);
	for (const retained of [unrelated, legacy])
		assert.equal(
			(await retained.user.collection("notes").doc("retained-note").get())
				.exists,
			true,
		);
});

test("reminder handler captures the correct recipient/date and cancellation prevents later reminders", async () => {
	const f = await fixture();
	const s = await schedule(f);
	await age(f, s, 29.5);
	const before = emails.length;
	await tick("sendDeletionReminders");
	const reminder = emails.slice(before).find((m) => m.to === f.email);
	assert.ok(reminder);
	assert.match(reminder.text, /UTC/);
	assert.doesNotMatch(reminder.text, /tomorrow/i);
	assert.equal(
		(await f.user.get()).data().scheduledDeletion.reminderSent,
		true,
	);
	await lifecycle.cancelDeletion(db, f.uid, "test");
	const count = emails.length;
	await tick("sendDeletionReminders");
	assert.equal(emails.length, count);
});

test("partial deletion retains a non-cancellable claim and retry finishes without false restoration", async () => {
	const f = await fixture();
	const s = await schedule(f);
	await age(f, s);
	await drainTokens(f, s);
	const originalBucket = storage.bucket;
	storage.bucket = () => ({
		getFiles: async () => {
			throw new Error("Synthetic storage outage");
		},
	});
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	try {
		const response = await fetch(`${origin}/processScheduledDeletions`, {
			method: "POST",
			headers: { "X-CloudScheduler-JobName": "local-failure-test" },
		});
		assert.equal(response.status, 500);
	} finally {
		storage.bucket = originalBucket;
	}
	assert.equal((await f.user.get()).data().scheduledDeletion.state, "deleting");
	assert.equal((await f.user.collection("notes").get()).empty, true);
	const before = emails.length;
	assert.equal((await call("cancelScheduledDeletion", f.token)).status, 401);
	assert.equal(emails.length, before);
	await f.user.update({
		"scheduledDeletion.leaseUntil": Timestamp.fromMillis(0),
	});
	// Emergency disable must also stop partial work, even after its lease expires.
	delete process.env.ACCOUNT_DELETION_ENABLED;
	await tick("processScheduledDeletions");
	assert.equal((await f.user.get()).exists, true);
	assert.equal(
		(await storage.bucket().file(`users/${f.uid}/attachment`).exists())[0],
		true,
	);
	// HTTP rejects the disabled Auth user before reaching the callable body.
	// Exercise the body separately to verify it preserves its terminal HttpsError.
	await assert.rejects(
		routes.createCustomToken.run({ auth: { uid: f.uid, token: {} }, data: {} }),
		{
			code: "failed-precondition",
			details: { reason: "account-deletion-in-progress" },
		},
	);
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	await tick("processScheduledDeletions");
	assert.equal((await f.user.get()).exists, false);
	assert.equal(
		(
			await db.collection("accountDeletionRequests").doc(s.requestId).get()
		).data().state,
		"completed",
	);
});

test("missing Auth and forged reminder proof are held without destroying data or sending mail", async () => {
	const f = await fixture();
	const s = await schedule(f);
	await age(f, s);
	await auth.deleteUser(f.uid);
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	const warnings = [];
	const warn = console.warn;
	console.warn = (...args) => warnings.push(args);
	try {
		await tick("processScheduledDeletions");
	} finally {
		console.warn = warn;
	}
	assert.ok(warnings.some((args) => args[1]?.reason === "missing-auth-user"));
	assert.equal((await f.user.get()).data().scheduledDeletion.state, "pending");
	const forged = await fixture();
	const fs = await schedule(forged);
	await age(forged, fs, 29.5);
	await db.collection("accountDeletionRequests").doc(fs.requestId).delete();
	const count = emails.length;
	await tick("sendDeletionReminders");
	assert.equal(emails.length, count);
});

test("retired OTP verifier cannot overwrite codes or reset the attempt limit and cooldown", async () => {
	assert.equal(
		(await call("verifyDeletionOtp", null, { otp: "123456" })).status,
		401,
	);
	const f = await fixture();
	assert.equal((await call("sendDeletionOtp", f.token)).status, 200);
	const ref = f.user.collection("otpVerification").doc("deletion");
	const original = await ref.get();
	const otp = original.data().otp;
	assert.equal((await call("verifyDeletionOtp", f.token, { otp })).status, 400);
	assert.ok((await ref.get()).updateTime.isEqual(original.updateTime));
	for (let i = 0; i < 5; i++) {
		assert.equal(
			(await call("scheduleAccountDeletion", f.token, { otp: "wrong-code" }))
				.status,
			403,
		);
	}
	const exhausted = await ref.get();
	assert.equal(exhausted.data().attempts, 5);
	assert.equal((await call("verifyDeletionOtp", f.token, { otp })).status, 400);
	assert.ok((await ref.get()).updateTime.isEqual(exhausted.updateTime));
	assert.equal(
		(await call("sendDeletionOtp", f.token)).error.details.reason,
		"deletion-otp-cooldown",
	);
	assert.equal(
		(await call("scheduleAccountDeletion", f.token, { otp })).status,
		429,
	);
	assert.equal((await f.user.get()).data().scheduledDeletion, undefined);
});

test("OTP retry returns cooldown details and keeps the original code usable", async () => {
	const f = await fixture();
	await call("sendDeletionOtp", f.token);
	const ref = f.user.collection("otpVerification").doc("deletion");
	const otp = (await ref.get()).data().otp;
	const count = emails.length;
	const retry = await call("sendDeletionOtp", f.token);
	assert.equal(retry.error.status, "RESOURCE_EXHAUSTED");
	assert.equal(retry.error.details.reason, "deletion-otp-cooldown");
	assert.ok(retry.error.details.retryAfterSeconds > 0);
	assert.equal(emails.length, count);
	assert.equal((await ref.get()).data().otp, otp);
	assert.equal(
		(await call("scheduleAccountDeletion", f.token, { otp })).status,
		200,
	);
});

test("held records spanning query pages do not starve an eligible request", async () => {
	const batch = db.batch();
	for (let i = 0; i < 105; i++)
		batch.set(db.collection("users").doc(`held-${randomUUID()}`), {
			scheduledDeletion: { deleteAt: Timestamp.fromMillis(0) },
		});
	await batch.commit();
	const f = await fixture();
	const s = await schedule(f);
	await age(f, s);
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	await tick("processScheduledDeletions");
	assert.equal((await f.user.get()).data().scheduledDeletion.state, "deleting");
	assert.equal((await auth.getUser(f.uid)).disabled, true);
});

test("bounded worker resumes from its checkpoint instead of skipping the remaining accounts", async () => {
	const fixtures = [];
	for (let i = 0; i < 26; i++) {
		const f = await fixture();
		const s = await schedule(f);
		await age(f, s);
		fixtures.push(f);
	}
	process.env.ACCOUNT_DELETION_ENABLED = "true";
	await tick("processScheduledDeletions");
	const countDisabled = async () =>
		(await Promise.all(fixtures.map((f) => auth.getUser(f.uid)))).filter(
			(u) => u.disabled,
		).length;
	assert.equal(await countDisabled(), 25);
	assert.equal(
		(await db.collection("accountDeletionWorker").doc("scan").get()).exists,
		true,
	);
	await tick("processScheduledDeletions");
	assert.equal(await countDisabled(), 26);
	assert.equal(
		(await db.collection("accountDeletionWorker").doc("scan").get()).exists,
		false,
	);
});

test("reminder delivery failure fails the job and a later retry marks success", async () => {
	const f = await fixture();
	const s = await schedule(f);
	await age(f, s, 29.5);
	const utils = require("../lib/utils");
	const originalSend = utils.sendEmail;
	utils.sendEmail = async () => {
		throw new Error("Synthetic SMTP outage");
	};
	try {
		const response = await fetch(`${origin}/sendDeletionReminders`, {
			method: "POST",
		});
		assert.equal(response.status, 500);
		assert.equal(
			(await f.user.get()).data().scheduledDeletion.reminderSent,
			false,
		);
	} finally {
		utils.sendEmail = originalSend;
	}
	await tick("sendDeletionReminders");
	assert.equal(
		(await f.user.get()).data().scheduledDeletion.reminderSent,
		true,
	);
});

test("paused deletion refuses new OTPs and schedules and suppresses reminders", async () => {
	const f = await fixture();
	const s = await schedule(f);
	await age(f, s, 29.5);
	// Scheduling revokes f's token. Use a fresh account to exercise the pause gate,
	// while retaining f's scheduled request to check reminder suppression.
	const requester = await fixture();
	delete process.env.ACCOUNT_DELETION_ENABLED;
	const count = emails.length;
	for (const name of ["sendDeletionOtp", "scheduleAccountDeletion"]) {
		const result = await call(name, requester.token, { otp: "123456" });
		assert.equal(result.error.details.reason, "account-deletion-paused");
	}
	await tick("sendDeletionReminders");
	assert.equal(emails.length, count);
	assert.equal(
		(await f.user.get()).data().scheduledDeletion.reminderSent,
		false,
	);
});

test("blocking sign-in fails safely on a transient deletion check error", async () => {
	const original = lifecycle.cancelDeletion;
	lifecycle.cancelDeletion = async () => {
		throw new Error("Synthetic transaction failure");
	};
	try {
		await assert.rejects(
			signInHook.run({
				data: { uid: "synthetic", email: "qa@example.invalid" },
				eventType: "providers/cloud.auth/eventTypes/user.beforeSignIn",
			}),
			{ code: "unavailable" },
		);
	} finally {
		lifecycle.cancelDeletion = original;
	}
});

test("missing reminder Auth user does not poison the remaining batch", async () => {
	const missing = await fixture();
	const valid = await fixture();
	await age(missing, await schedule(missing), 29.5);
	await age(valid, await schedule(valid), 29.5);
	await auth.deleteUser(missing.uid);
	await tick("sendDeletionReminders");
	assert.equal(
		(await valid.user.get()).data().scheduledDeletion.reminderSent,
		true,
	);
});

test("sign-in cancellation emails independently of the client and event retry is idempotent", async () => {
	const f = await fixture();
	const s = await schedule(f);
	const ref = db.collection("accountDeletionRequests").doc(s.requestId);
	const before = await ref.get();
	await lifecycle.cancelDeletion(db, f.uid, "beforeUserSignedIn");
	const after = await ref.get();
	const handler = require("../lib/exports/sendDeletionCancellation").default;
	const event = { params: { requestId: s.requestId }, data: { before, after } };
	const start = emails.length;
	const utils = require("../lib/utils");
	const original = utils.sendEmail;
	utils.sendEmail = async () => {
		throw new Error("Synthetic SMTP outage");
	};
	try {
		await assert.rejects(handler.run(event), /Synthetic SMTP outage/);
		assert.equal((await ref.get()).data().cancellationEmailSentAt, undefined);
	} finally {
		utils.sendEmail = original;
	}
	await handler.run(event);
	await handler.run(event);
	assert.equal(emails.length, start + 1);
	assert.equal(emails.at(-1).to, f.email);
	assert.ok((await ref.get()).data().cancellationEmailSentAt);
});

test("OTP responses mask one- and two-character email local parts", async () => {
	for (const local of ["a", "ab"]) {
		const f = await fixture();
		const domain = `${f.uid}.example.invalid`;
		await auth.updateUser(f.uid, { email: `${local}@${domain}` });
		const result = await call("sendDeletionOtp", f.token);
		assert.equal(result.status, 200);
		assert.equal(
			result.result.email,
			`${local.length > 1 ? "a" : ""}***@${domain}`,
		);
	}
});


test("undeliverable cancellation notices have a terminal skipped marker", async () => {
 const f = await fixture();
 const s = await schedule(f);
 const ref = db.collection("accountDeletionRequests").doc(s.requestId);
 const before = await ref.get();
 await lifecycle.cancelDeletion(db, f.uid, "test");
 const after = await ref.get();
 await auth.deleteUser(f.uid);
 const event = {params: {requestId: s.requestId}, data: {before, after}};
 const handler = require("../lib/exports/sendDeletionCancellation").default;
 const count = emails.length;
 await handler.run(event);
 await handler.run(event);
 assert.equal(emails.length, count);
 assert.equal((await ref.get()).data().cancellationEmailSkippedReason, "user-not-found");
});


test("scheduling fences fresh sign-in until the durable trigger revokes old Auth tokens", async () => {
 const f = await fixture();
 // Auth revocation epochs have second resolution.
 await new Promise(resolve => setTimeout(resolve, 1100));
 const s = await schedule(f, {completeRevocation: false});
 await assert.rejects(lifecycle.cancelDeletion(db, f.uid, "beforeUserSignedIn"), {code: "unavailable"});
 const ref = db.collection("accountDeletionRequests").doc(s.requestId);
 const event = {params: {requestId: s.requestId}, data: await ref.get()};
 const handler = require("../lib/exports/revokeScheduledDeletionSessions").default;
 await handler.run(event);
 await assert.rejects(auth.verifyIdToken(f.token, true), {code: "auth/id-token-revoked"});
 const epoch = (await auth.getUser(f.uid)).tokensValidAfterTime;
 assert.equal(await lifecycle.cancelDeletion(db, f.uid, "beforeUserSignedIn"), true);
 await handler.run(event); // An old Eventarc delivery must not revoke a new session.
 assert.equal((await auth.getUser(f.uid)).tokensValidAfterTime, epoch);
});
