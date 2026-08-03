const assert = require("node:assert/strict");
const test = require("node:test");
const admin = require("firebase-admin");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const {
	consumeAccountLinkSession,
	InvalidAccountLinkSessionError,
} = require("../lib/accountLinkSession");

test(
	"only one concurrent account-link session consumer succeeds",
	{ timeout: 30_000 },
	async () => {
		assert.ok(
			process.env.FIRESTORE_EMULATOR_HOST,
			"FIRESTORE_EMULATOR_HOST must be provided by emulators:exec",
		);

		const suffix = `${Date.now()}-${process.pid}`;
		const app = admin.initializeApp(
			{ projectId: "better-keep-notes" },
			`account-link-session-${suffix}`,
		);
		const db = getFirestore(app);
		const sessionRef = db.collection("accountLinkSessions").doc(suffix);
		await sessionRef.set({
			uid: "user-1",
			provider: "github.com",
			status: "issued",
			authorizationExpiresAt: Timestamp.fromMillis(Date.now() + 60_000),
			consumedAt: null,
		});

		try {
			const attempts = await Promise.allSettled([
				consumeAccountLinkSession({
					db,
					sessionRef,
					expectation: { uid: "user-1", provider: "github.com" },
					consumedAt: Timestamp.now(),
				}),
				consumeAccountLinkSession({
					db,
					sessionRef,
					expectation: { uid: "user-1", provider: "github.com" },
					consumedAt: Timestamp.now(),
				}),
			]);
			const fulfilled = attempts.filter(
				(result) => result.status === "fulfilled",
			);
			const rejected = attempts.filter(
				(result) => result.status === "rejected",
			);

			assert.equal(fulfilled.length, 1);
			assert.equal(rejected.length, 1);
			assert.ok(rejected[0].reason instanceof InvalidAccountLinkSessionError);
			const consumed = (await sessionRef.get()).data();
			assert.ok(consumed.consumedAt);
			assert.equal(consumed.status, "custom_confirmed");
		} finally {
			await sessionRef.delete().catch(() => {});
			await app.delete();
		}
	},
);
