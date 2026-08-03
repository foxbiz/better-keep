const assert = require("node:assert/strict");
const test = require("node:test");
const admin = require("firebase-admin");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const {
	redeemOAuthCompletionWithDependencies,
} = require("../lib/oauthCompletion");
const {
	challengeForVerifier,
	createOpaqueToken,
	hashOpaqueToken,
} = require("../lib/oauthSession");

async function seedCompletion(db, { code, verifier, suffix }) {
	const ref = db.collection("oauthCompletions").doc(hashOpaqueToken(code));
	await ref.set({
		uid: `oauth-user-${suffix}`,
		provider: "github",
		challenge: challengeForVerifier(verifier),
		status: "pending",
		attemptId: null,
		leaseExpiresAt: null,
		expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
		deleteAfter: Timestamp.fromMillis(Date.now() + 120_000),
	});
	return ref;
}

test(
	"OAuth completion rejects wrong verifiers, concurrency, and replay",
	{ timeout: 30_000 },
	async () => {
		assert.ok(process.env.FIRESTORE_EMULATOR_HOST);
		const suffix = `${Date.now()}-${process.pid}`;
		const app = admin.initializeApp(
			{ projectId: "better-keep-notes" },
			`oauth-completion-${suffix}`,
		);
		const firestore = getFirestore(app);
		const code = createOpaqueToken();
		const verifier = createOpaqueToken();
		const ref = await seedCompletion(firestore, { code, verifier, suffix });
		let tokenCreations = 0;
		const createCustomToken = async (uid) => {
			tokenCreations += 1;
			await new Promise((resolve) => setTimeout(resolve, 25));
			return `token-for-${uid}`;
		};

		try {
			await assert.rejects(
				redeemOAuthCompletionWithDependencies({
					code,
					verifier: createOpaqueToken(),
					firestore,
					createCustomToken,
				}),
				(error) => error.code === "permission-denied",
			);

			const attempts = await Promise.allSettled([
				redeemOAuthCompletionWithDependencies({
					code,
					verifier,
					firestore,
					createCustomToken,
				}),
				redeemOAuthCompletionWithDependencies({
					code,
					verifier,
					firestore,
					createCustomToken,
				}),
			]);
			assert.equal(
				attempts.filter((result) => result.status === "fulfilled").length,
				1,
			);
			assert.equal(
				attempts.filter((result) => result.status === "rejected").length,
				1,
			);
			assert.equal(tokenCreations, 1);
			assert.equal((await ref.get()).exists, false);
			await assert.rejects(
				redeemOAuthCompletionWithDependencies({
					code,
					verifier,
					firestore,
					createCustomToken,
				}),
				(error) => error.code === "permission-denied",
			);
		} finally {
			await ref.delete().catch(() => undefined);
			await app.delete();
		}
	},
);

test(
	"OAuth completion releases its lease after token creation failure",
	{ timeout: 30_000 },
	async () => {
		const suffix = `${Date.now()}-${process.pid}-retry`;
		const app = admin.initializeApp(
			{ projectId: "better-keep-notes" },
			`oauth-completion-${suffix}`,
		);
		const firestore = getFirestore(app);
		const code = createOpaqueToken();
		const verifier = createOpaqueToken();
		const ref = await seedCompletion(firestore, { code, verifier, suffix });
		try {
			await assert.rejects(
				redeemOAuthCompletionWithDependencies({
					code,
					verifier,
					firestore,
					createCustomToken: async () => {
						throw new Error("transient signer failure");
					},
				}),
				(error) => error.code === "internal",
			);
			assert.equal((await ref.get()).data().status, "pending");
			const token = await redeemOAuthCompletionWithDependencies({
				code,
				verifier,
				firestore,
				createCustomToken: async () => "retry-token",
			});
			assert.equal(token, "retry-token");
			assert.equal((await ref.get()).exists, false);
		} finally {
			await ref.delete().catch(() => undefined);
			await app.delete();
		}
	},
);

test(
	"OAuth completion never reclaims an ambiguous expired lease",
	{ timeout: 30_000 },
	async () => {
		const suffix = `${Date.now()}-${process.pid}-stale`;
		const app = admin.initializeApp(
			{ projectId: "better-keep-notes" },
			`oauth-completion-${suffix}`,
		);
		const firestore = getFirestore(app);
		const code = createOpaqueToken();
		const verifier = createOpaqueToken();
		const ref = await seedCompletion(firestore, { code, verifier, suffix });
		await ref.update({
			status: "redeeming",
			attemptId: createOpaqueToken(),
			leaseExpiresAt: Timestamp.fromMillis(Date.now() - 1),
		});
		let tokenCreations = 0;
		try {
			await assert.rejects(
				redeemOAuthCompletionWithDependencies({
					code,
					verifier,
					firestore,
					createCustomToken: async () => {
						tokenCreations += 1;
						return "must-not-be-created";
					},
				}),
				(error) => error.code === "aborted",
			);
			assert.equal(tokenCreations, 0);
			assert.equal((await ref.get()).data().status, "redeeming");
		} finally {
			await ref.delete().catch(() => undefined);
			await app.delete();
		}
	},
);
