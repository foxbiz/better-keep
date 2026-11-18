const assert = require("node:assert/strict");
const { test, after } = require("node:test");
const { randomUUID } = require("node:crypto");
assert.match(
	process.env.FIRESTORE_EMULATOR_HOST || "",
	/^(127\.0\.0\.1|localhost):\d+$/,
);
process.env.GCLOUD_PROJECT = "demo-better-keep-deletion";
process.env.FUNCTIONS_EMULATOR = "true";
const { Timestamp } = require("firebase-admin/firestore");
const { db, app } = require("../lib/config");
const {
	scheduleDeletion: beginDeletion,
	cancelDeletion,
	claimDeletion,
	finishDeletion,
	markDeletionReminderSent,
	DELETION_GRACE_MS,
	deletionDateLabel,
} = require("../lib/accountDeletionLifecycle");
const { revokeDeletionSessions, REVOCATION_LEASE_MS } = require("../lib/deletionSessionRevocation");
async function scheduleDeletion(...args) {
 const schedule = await beginDeletion(...args);
 await revokeDeletionSessions(args[0], args[1], schedule.requestId, async () => {}, () => args[3] || Timestamp.now());
 return {...schedule, state: "pending"};
}
const now = Timestamp.fromMillis(Date.parse("2026-10-02T10:00:00Z"));
const due = Timestamp.fromMillis(now.toMillis() + DELETION_GRACE_MS);
async function fixture() {
	const uid = `lifecycle-${randomUUID()}`;
	const user = db.collection("users").doc(uid);
	await user.set({ displayName: "Synthetic test account" });
	await user
		.collection("otpVerification")
		.doc("deletion")
		.set({
			otp: "123456",
			attempts: 0,
			createdAt: now,
			expiresAt: Timestamp.fromMillis(now.toMillis() + 600000),
		});
	return { uid, user };
}
after(() => app.delete());

test("OTP is single-use under concurrent requests; proof and 30-day schedule commit together", async () => {
	const f = await fixture();
	const result = await Promise.allSettled(
		[1, 2].map(() => scheduleDeletion(db, f.uid, "123456", now)),
	);
	assert.equal(result.filter((x) => x.status === "fulfilled").length, 1);
	const s = (await f.user.get()).data().scheduledDeletion;
	assert.equal(
		s.deleteAt.toMillis() - s.scheduledAt.toMillis(),
		DELETION_GRACE_MS,
	);
	assert.equal(
		(await f.user.collection("otpVerification").doc("deletion").get()).exists,
		false,
	);
	const proof = (
		await db.collection("accountDeletionRequests").doc(s.requestId).get()
	).data();
	assert.equal(proof.uid, f.uid);
	assert.equal(proof.verification, "email_otp");
});

test("failed OTP attempts commit and the sixth attempt is blocked", async () => {
	const f = await fixture();
	for (let i = 0; i < 5; i++)
		await assert.rejects(scheduleDeletion(db, f.uid, "wrong", now), {
			code: "permission-denied",
		});
	await assert.rejects(scheduleDeletion(db, f.uid, "123456", now), {
		code: "resource-exhausted",
	});
	assert.equal((await f.user.get()).data().scheduledDeletion, undefined);
});

test("expired and missing-expiry codes fail closed", async () => {
	for (const expiresAt of [now, null]) {
		const f = await fixture();
		await f.user
			.collection("otpVerification")
			.doc("deletion")
			.update({ expiresAt });
		await assert.rejects(scheduleDeletion(db, f.uid, "123456", now), {
			code: "deadline-exceeded",
		});
	}
});

test("cancellation fences a worker's stale candidate and delayed OTP use", async () => {
	const f = await fixture();
	const s = await scheduleDeletion(db, f.uid, "123456", now);
	assert.equal(await cancelDeletion(db, f.uid, "test-login", due), true);
	assert.equal(
		await claimDeletion(db, f.uid, s.requestId, now.toMillis() - 1000, due),
		null,
	);
	await assert.rejects(scheduleDeletion(db, f.uid, "123456", due));
	assert.equal((await f.user.get()).data().scheduledDeletion, undefined);
});

test("cancellation and destructive claim never both succeed, including contention failures", async () => {
	for (let i = 0; i < 5; i++) {
		const f = await fixture();
		const s = await scheduleDeletion(db, f.uid, "123456", now);
		const [cancel, claim] = await Promise.allSettled([
			cancelDeletion(db, f.uid, "race", due),
			claimDeletion(db, f.uid, s.requestId, now.toMillis() - 1000, due),
		]);
		// The emulator can invalidate a contended transaction instead of returning
		// retryable ABORTED. This must fail closed, never promise successful cancellation.
		for (const result of [cancel, claim]) {
			if (result.status === "rejected")
				assert.ok(
					result.reason.code === "failed-precondition" ||
						(result.reason.code === 3 &&
							result.reason.message.includes(
								"Transaction is invalid or closed",
							)),
					result.reason.stack,
				);
		}
		const state = (await f.user.get()).data().scheduledDeletion;
		const proof = (
			await db.collection("accountDeletionRequests").doc(s.requestId).get()
		).data();
		if (cancel.status === "fulfilled") {
			assert.equal(cancel.value, true);
			assert.ok(claim.status === "rejected" || claim.value === null);
			assert.equal(state, undefined);
			assert.equal(proof.state, "cancelled");
		} else if (claim.status === "fulfilled" && claim.value) {
			assert.equal(state.state, "deleting");
			assert.equal(state.leaseId, claim.value);
			assert.equal(proof.state, "deleting");
			await assert.rejects(cancelDeletion(db, f.uid, "retry", due), {
				code: "failed-precondition",
			});
		} else {
			assert.equal(state.state, "pending");
			assert.equal(proof.state, "pending");
			assert.equal(await cancelDeletion(db, f.uid, "retry", due), true);
		}
	}
});

test("only one worker claims a request; cancellation cannot promise safety once claimed", async () => {
	const f = await fixture();
	const s = await scheduleDeletion(db, f.uid, "123456", now);
	const results = await Promise.allSettled(
		[1, 2].map(() =>
			claimDeletion(db, f.uid, s.requestId, now.toMillis() - 1000, due),
		),
	);
	// Emulator contention can close the losing transaction instead of returning
	// ABORTED. Still require exactly one successful claim and its persisted lease.
	for (const result of results) {
		if (result.status === "rejected") {
			assert.equal(result.reason.code, 3);
			assert.match(result.reason.message, /Transaction is invalid or closed/);
		}
	}
	const leases = results.filter(r => r.status === "fulfilled").map(r => r.value).filter(Boolean);
	assert.equal(leases.length, 1);
	assert.equal((await f.user.get()).data().scheduledDeletion.leaseId, leases[0]);
	await assert.rejects(cancelDeletion(db, f.uid, "late-login", due), {
		code: "failed-precondition",
	});
	await assert.rejects(
		finishDeletion(db, f.uid, s.requestId, "wrong-lease", "adminUsers"),
	);
	assert.equal((await f.user.get()).exists, true);
	await finishDeletion(
		db,
		f.uid,
		s.requestId,
		leases.find(Boolean),
		"adminUsers",
	);
	assert.equal((await f.user.get()).exists, false);
	assert.equal(
		(
			await db.collection("accountDeletionRequests").doc(s.requestId).get()
		).data().state,
		"completed",
	);
});

test("legacy and forged requests never authorize deletion, but remain cancellable", async () => {
	const f = await fixture();
	for (const marker of [
		{ deleteAt: due },
		{
			version: 2,
			state: "pending",
			requestId: randomUUID(),
			deleteAt: due,
			scheduledAt: now,
		},
		{ state: "deleting", requestId: "invalid/path" },
	]) {
		await f.user.update({ scheduledDeletion: marker });
		assert.equal(
			await claimDeletion(db, f.uid, marker.requestId || "legacy", 0, due),
			null,
		);
		assert.equal(await cancelDeletion(db, f.uid, "legacy-login", due), true);
	}
});

test("recent sign-in and shortened grace periods prevent destructive claims", async () => {
	const f = await fixture();
	const s = await scheduleDeletion(db, f.uid, "123456", now);
	assert.equal(
		await claimDeletion(db, f.uid, s.requestId, now.toMillis() + 1, due),
		null,
	);
	assert.equal(await claimDeletion(db, f.uid, s.requestId, NaN, due), null);
	await f.user.update({ "scheduledDeletion.deleteAt": now });
	assert.equal(await claimDeletion(db, f.uid, s.requestId, 0, due), null);
});

test("reminder completion cannot recreate cancellation state or mark a newer request", async () => {
	const f = await fixture();
	const s = await scheduleDeletion(db, f.uid, "123456", now);
	await cancelDeletion(db, f.uid, "test", due);
	await markDeletionReminderSent(db, f.uid, s.requestId);
	assert.equal((await f.user.get()).data().scheduledDeletion, undefined);
	await f.user.update({
		scheduledDeletion: {
			requestId: randomUUID(),
			state: "pending",
			reminderSent: false,
		},
	});
	await markDeletionReminderSent(db, f.uid, s.requestId);
	assert.equal(
		(await f.user.get()).data().scheduledDeletion.reminderSent,
		false,
	);
});

test("deadline text includes a fixed UTC timezone", () => {
	assert.match(deletionDateLabel(due), /November 1, 2026.*10:00 UTC/);
});

test("ordinary cancellation is read-only; pending OTP cancellation still fences scheduling", async () => {
	const uid = `no-deletion-${randomUUID()}`;
	const user = db.collection("users").doc(uid);
	await user.set({ displayName: "Unchanged" });
	const before = await user.get();
	assert.equal(await cancelDeletion(db, uid, "sign-in", now), false);
	assert.ok((await user.get()).updateTime.isEqual(before.updateTime));
	const f = await fixture();
	assert.equal(await cancelDeletion(db, f.uid, "sign-in", now), false);
	await assert.rejects(scheduleDeletion(db, f.uid, "123456", now));
});

test("token drain and lease checks fail closed and re-enabled Auth restarts the wait", async () => {
	const {
		recordDeletionAuthInvalidation,
		renewDeletionLease,
		DELETION_TOKEN_DRAIN_MS,
	} = require("../lib/accountDeletionLifecycle");
	const f = await fixture();
	const s = await scheduleDeletion(db, f.uid, "123456", now);
	const lease = await claimDeletion(db, f.uid, s.requestId, 0, due);
	assert.equal(
		await recordDeletionAuthInvalidation(
			db,
			f.uid,
			s.requestId,
			lease,
			false,
			due,
		),
		false,
	);
	const later = Timestamp.fromMillis(due.toMillis() + DELETION_TOKEN_DRAIN_MS);
	assert.equal(
		await recordDeletionAuthInvalidation(
			db,
			f.uid,
			s.requestId,
			lease,
			true,
			later,
		),
		true,
	);
	assert.equal(
		await recordDeletionAuthInvalidation(
			db,
			f.uid,
			s.requestId,
			lease,
			false,
			later,
		),
		false,
	);
	await assert.rejects(renewDeletionLease(db, f.uid, "wrong", due));
	await assert.rejects(renewDeletionLease(db, f.uid, lease, later));
	await renewDeletionLease(db, f.uid, lease, due);
});

test("midnight deadline never renders as 24:00", () => {
	assert.match(
		deletionDateLabel(Timestamp.fromMillis(Date.parse("2026-11-01T00:00:00Z"))),
		/00:00 UTC/,
	);
});


test("revocation fences cancellation and deletion until Auth succeeds; duplicate events are harmless", async () => {
 const f = await fixture();
 const s = await beginDeletion(db, f.uid, "123456", now);
 let release, entered;
 const started = new Promise(r => entered = r);
 const blocked = new Promise(r => release = r);
 let calls = 0;
 const work = revokeDeletionSessions(db, f.uid, s.requestId, async () => { calls++; entered(); await blocked; }, () => now);
 await started;
 await assert.rejects(cancelDeletion(db, f.uid, "sign-in", now), {code: "unavailable"});
 assert.equal(await claimDeletion(db, f.uid, s.requestId, 0, due), null);
 await assert.rejects(revokeDeletionSessions(db, f.uid, s.requestId, async () => { calls++; }, () => now), /in progress/);
 release();
 await work;
 assert.equal(await cancelDeletion(db, f.uid, "sign-in", now), true);
 await revokeDeletionSessions(db, f.uid, s.requestId, async () => { calls++; }, () => now);
 assert.equal(calls, 1);
});

test("settled Auth failure stays fenced and allows an event retry", async () => {
 const f = await fixture();
 const s = await beginDeletion(db, f.uid, "123456", now);
 await assert.rejects(revokeDeletionSessions(db, f.uid, s.requestId, async () => {throw new Error("Auth unavailable");}, () => now), /Auth unavailable/);
 await assert.rejects(cancelDeletion(db, f.uid, "sign-in", now), {code: "unavailable"});
 const later = Timestamp.fromMillis(now.toMillis() + REVOCATION_LEASE_MS + 1);
 await revokeDeletionSessions(db, f.uid, s.requestId, async () => {}, () => later);
 assert.equal((await f.user.get()).data().scheduledDeletion.state, "pending");
 assert.equal(await cancelDeletion(db, f.uid, "sign-in", later), true);
});


test("a timed-out but running Auth attempt cannot be stolen after lease expiry", async () => {
 const f = await fixture();
 const s = await beginDeletion(db, f.uid, "123456", now);
 let clock = now;
 let release, entered;
 const started = new Promise(r => entered = r);
 const blocked = new Promise(r => release = r);
 const work = revokeDeletionSessions(db, f.uid, s.requestId, async () => { entered(); await blocked; }, () => clock);
 await started;
 clock = Timestamp.fromMillis(now.toMillis() + REVOCATION_LEASE_MS + 1);
 let duplicateCalls = 0;
 await assert.rejects(revokeDeletionSessions(db, f.uid, s.requestId, async () => { duplicateCalls++; }, () => clock), /in progress/);
 await assert.rejects(cancelDeletion(db, f.uid, "sign-in", clock), {code: "unavailable"});
 assert.equal(duplicateCalls, 0);
 release();
 await work;
 assert.equal(await cancelDeletion(db, f.uid, "sign-in", clock), true);
});

test("an expired pre-dispatch attempt cannot invoke Auth", async () => {
 const f = await fixture();
 const s = await beginDeletion(db, f.uid, "123456", now);
 let reads = 0, calls = 0;
 const later = Timestamp.fromMillis(now.toMillis() + REVOCATION_LEASE_MS + 1);
 await assert.rejects(revokeDeletionSessions(db, f.uid, s.requestId, async () => {calls++;}, () => ++reads === 1 ? now : later), /expired/);
 assert.equal(calls, 0);
 await revokeDeletionSessions(db, f.uid, s.requestId, async () => {calls++;}, () => later);
 assert.equal(calls, 1);
 assert.equal(await cancelDeletion(db, f.uid, "sign-in", later), true);
});

// Faults surround real Firestore transactions, rather than mocking lifecycle state.
function faultTransactions(intercept) {
	let number = 0;
	return {
		collection: db.collection.bind(db),
		runTransaction: (...args) =>
			intercept(++number, () => db.runTransaction(...args)),
	};
}

test("failed completion commit releases only the settled attempt and event retry finishes", async () => {
	const f = await fixture();
	const s = await beginDeletion(db, f.uid, "123456", now);
	const audit = db.collection("accountDeletionRequests").doc(s.requestId);
	let calls = 0;
	const faulty = faultTransactions((n, run) =>
		n === 3 ? Promise.reject(new Error("Completion unavailable")) : run(),
	);
	await assert.rejects(
		revokeDeletionSessions(
			faulty,
			f.uid,
			s.requestId,
			async () => {
				calls++;
			},
			() => now,
		),
		/Completion unavailable/,
	);
	assert.equal((await audit.get()).data().revocationDispatchedAt, undefined);
	assert.equal((await f.user.get()).data().scheduledDeletion.state, "revoking");
	await assert.rejects(cancelDeletion(db, f.uid, "sign-in", now), {
		code: "unavailable",
	});
	await revokeDeletionSessions(
		db,
		f.uid,
		s.requestId,
		async () => {
			calls++;
		},
		() => now,
	);
	assert.equal(calls, 2);
	assert.equal(await cancelDeletion(db, f.uid, "sign-in", now), true);
});

test("lost completion acknowledgement cannot alter cancellation or a new request", async () => {
	const f = await fixture();
	const s = await beginDeletion(db, f.uid, "123456", now);
	let next;
	const faulty = faultTransactions(async (n, run) => {
		const result = await run();
		if (n === 3) {
			await cancelDeletion(db, f.uid, "sign-in", now);
			await f.user
				.collection("otpVerification")
				.doc("deletion")
				.set({
					otp: "123456",
					attempts: 0,
					createdAt: now,
					expiresAt: Timestamp.fromMillis(now.toMillis() + 60000),
				});
			next = await beginDeletion(db, f.uid, "123456", now);
			throw new Error("Commit reply lost");
		}
		return result;
	});
	let calls = 0;
	await assert.rejects(
		revokeDeletionSessions(
			faulty,
			f.uid,
			s.requestId,
			async () => {
				calls++;
			},
			() => now,
		),
		/Commit reply lost/,
	);
	await revokeDeletionSessions(
		db,
		f.uid,
		s.requestId,
		async () => {
			calls++;
		},
		() => now,
	);
	assert.equal(calls, 1);
	assert.equal(
		(
			await db.collection("accountDeletionRequests").doc(s.requestId).get()
		).data().state,
		"cancelled",
	);
	assert.equal(
		(await f.user.get()).data().scheduledDeletion.requestId,
		next.requestId,
	);
	assert.equal((await f.user.get()).data().scheduledDeletion.state, "revoking");
});

test("completion compensation cannot clear a replacement attempt", async () => {
	const f = await fixture();
	const s = await beginDeletion(db, f.uid, "123456", now);
	const audit = db.collection("accountDeletionRequests").doc(s.requestId);
	const replacement = randomUUID();
	const faulty = faultTransactions(async (n, run) => {
		if (n === 3) {
			await audit.update({ revocationAttempt: replacement });
			throw new Error("Attempt replaced");
		}
		return run();
	});
	await assert.rejects(
		revokeDeletionSessions(
			faulty,
			f.uid,
			s.requestId,
			async () => {},
			() => now,
		),
		/Attempt replaced/,
	);
	const proof = (await audit.get()).data();
	assert.equal(proof.revocationAttempt, replacement);
	assert.equal(proof.revocationDispatchedAt.toMillis(), now.toMillis());
});

test("stranded dispatch recovery is explicit, account scoped, and preserves notes", async () => {
	const { execFile } = require("node:child_process");
	const { promisify } = require("node:util");
	const path = require("node:path");
	const exec = promisify(execFile);
	const f = await fixture();
	const note = f.user.collection("notes").doc("keep");
	await note.set({ content: "Synthetic note must survive recovery" });
	const s = await beginDeletion(db, f.uid, "123456", now);
	const audit = db.collection("accountDeletionRequests").doc(s.requestId);
	const faulty = faultTransactions((n, run) =>
		n >= 3 ? Promise.reject(new Error("Firestore unavailable")) : run(),
	);
	await assert.rejects(
		revokeDeletionSessions(
			faulty,
			f.uid,
			s.requestId,
			async () => {},
			() => now,
		),
		/Firestore unavailable/,
	);
	const before = (await audit.get()).data();
	assert.ok(before.revocationDispatchedAt instanceof Timestamp);
	let calls = 0;
	await assert.rejects(
		revokeDeletionSessions(db, f.uid, s.requestId, async () => {
			calls++;
		}),
		/in progress/,
	);
	assert.equal(calls, 0);
	const script = path.resolve(
		__dirname,
		"../scripts/recoverDeletionSessions.mjs",
	);
	const base = [
		script,
		"--project=demo-better-keep-deletion",
		"--database=(default)",
		`--uid=${f.uid}`,
		`--request-id=${s.requestId}`,
		`--attempt=${before.revocationAttempt}`,
	];
	const run = (args = base) =>
		exec(process.execPath, args, { env: process.env });
	await assert.rejects(
		run([...base, "--execute"]),
		/confirm-invocation-stopped/,
	);
	await assert.rejects(
		run([
			...base.slice(0, -1),
			`--attempt=${randomUUID()}`,
			"--execute",
			"--confirm-invocation-stopped",
		]),
		/does not match/,
	);
	await assert.rejects(
		run(
			base.map((x) =>
				x === `--uid=${f.uid}` ? "--uid=other-synthetic-owner" : x,
			),
		),
		/does not match/,
	);
	assert.match((await run()).stdout, /Dry run/);
	assert.deepEqual((await audit.get()).data(), before);
	// Even explicit operator confirmation cannot override an active lease.
	await audit.update({
		revocationLeaseUntil: Timestamp.fromMillis(Date.now() + 60000),
	});
	await assert.rejects(
		run([...base, "--execute", "--confirm-invocation-stopped"]),
		/lease has not expired/,
	);
	await audit.update({ revocationLeaseUntil: before.revocationLeaseUntil });
	await run([...base, "--execute", "--confirm-invocation-stopped"]);
	const after = (await audit.get()).data();
	assert.equal(after.state, "pending");
	assert.equal(after.revocationRecoveredAttempt, before.revocationAttempt);
	assert.equal(after.revocationDispatchedAt, undefined);
	assert.equal((await f.user.get()).data().scheduledDeletion.state, "pending");
	assert.equal(
		(await note.get()).data().content,
		"Synthetic note must survive recovery",
	);
	await assert.rejects(
		run([...base, "--execute", "--confirm-invocation-stopped"]),
		/does not match/,
	);
	assert.equal(await cancelDeletion(db, f.uid, "sign-in"), true);
});
