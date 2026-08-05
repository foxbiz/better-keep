const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");

process.env.FUNCTIONS_EMULATOR = "true";
const { db } = require("../lib/config");
const {
	authorizeNativeAccountLink,
} = require("../lib/nativeAccountLinkPolicy");

test(
	"native account-link authorization is consumed exactly once",
	{ timeout: 30_000 },
	async () => {
		assert.ok(process.env.FIRESTORE_EMULATOR_HOST);
		const suffix = `${Date.now()}-${process.pid}`;
		const uid = `native-link-${suffix}`;
		const provider = "google.com";
		const sessionId = `session-${suffix}`;
		const userRef = db.collection("users").doc(uid);
		const pendingRef = userRef.collection("pendingProviderLinks").doc(provider);
		const sessionRef = db.collection("accountLinkSessions").doc(sessionId);
		const authorizationExpiresAt = Timestamp.fromMillis(Date.now() + 60_000);
		await Promise.all([
			userRef.set({ email: `${uid}@example.test` }),
			pendingRef.set({
				uid,
				provider,
				sessionId,
				authorizationExpiresAt,
			}),
			sessionRef.set({
				uid,
				provider,
				status: "issued",
				authorizationExpiresAt,
			}),
		]);

		const event = {
			eventId: `event-${suffix}`,
			data: { uid, providerData: [{ providerId: "password" }] },
		};
		try {
			const results = await Promise.allSettled([
				authorizeNativeAccountLink(event, provider),
				authorizeNativeAccountLink(event, provider),
			]);
			assert.equal(
				results.filter((result) => result.status === "fulfilled").length,
				1,
			);
			assert.equal(
				results.filter((result) => result.status === "rejected").length,
				1,
			);
			assert.equal((await pendingRef.get()).exists, false);
			const session = (await sessionRef.get()).data();
			assert.equal(session.status, "native_authorized");
			assert.equal(session.authEventId, `event-${suffix}`);
		} finally {
			await Promise.all([
				db.recursiveDelete(userRef),
				sessionRef.delete(),
			]).catch(() => undefined);
		}
	},
);
