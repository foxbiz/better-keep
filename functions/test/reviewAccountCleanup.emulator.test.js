const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const test = require("node:test");
const admin = require("firebase-admin");
const { getFirestore } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const {
	cleanupReviewAccountData,
} = require("../lib/reviewAccountCleanup");

test(
	"cleanup removes all review-owned resources and preserves other users",
	{ timeout: 30_000 },
	async () => {
		assert.ok(
			process.env.FIRESTORE_EMULATOR_HOST,
			"FIRESTORE_EMULATOR_HOST must be provided by emulators:exec",
		);
		assert.ok(
			process.env.FIREBASE_STORAGE_EMULATOR_HOST,
			"FIREBASE_STORAGE_EMULATOR_HOST must be provided by emulators:exec",
		);

		const suffix = `${Date.now()}-${process.pid}`;
		const projectId = "better-keep-notes";
		const reviewUid = `review-cleanup-${suffix}`;
		const otherUid = `other-cleanup-${suffix}`;
		const reviewEmail = `review-${suffix}@example.com`;
		const reviewSubscriptionId = `review-subscription-${suffix}`;
		const otherSubscriptionId = `other-subscription-${suffix}`;
		const reviewShareId = `review-share-${suffix}`;
		const otherShareId = `other-share-${suffix}`;
		const app = admin.initializeApp(
			{
				projectId,
				storageBucket: `${projectId}.appspot.com`,
			},
			`review-cleanup-${suffix}`,
		);
		const db = getFirestore(app);
		const bucket = getStorage(app).bucket();
		const reviewPayment = db.collection("payments").doc(`payment-${suffix}`);
		const reviewLinkSession = db
			.collection("accountLinkSessions")
			.doc(`link-${suffix}`);
		const reviewOAuthState = db
			.collection("oauthStates")
			.doc(`oauth-${suffix}`);
		const reviewOAuthCompletion = db
			.collection("oauthCompletions")
			.doc(`completion-${suffix}`);
		const reviewUser = db.collection("users").doc(reviewUid);
		const otherUser = db.collection("users").doc(otherUid);
		const reviewSubscription = db
			.collection("subscriptions")
			.doc(reviewSubscriptionId);
		const otherSubscription = db
			.collection("subscriptions")
			.doc(otherSubscriptionId);
		const reviewShare = db.collection("shares").doc(reviewShareId);
		const otherShare = db.collection("shares").doc(otherShareId);
		const reviewTrialUsage = db
			.collection("trialUsage")
			.doc(reviewEmail.toLowerCase());
		const reviewPasswordReset = db
			.collection("passwordResetOtps")
			.doc(
				crypto
					.createHash("sha256")
					.update(reviewEmail.toLowerCase())
					.digest("hex"),
			);
		const reviewUserFile = bucket.file(
			`users/${reviewUid}/attachments/note.txt`,
		);
		const reviewShareFile = bucket.file(
			`shares/${reviewUid}/${reviewShareId}/attachment.txt`,
		);
		const otherUserFile = bucket.file(
			`users/${otherUid}/attachments/note.txt`,
		);
		const otherShareFile = bucket.file(
			`shares/${otherUid}/${otherShareId}/attachment.txt`,
		);

		try {
			await Promise.all([
				reviewUser.set({ email: reviewEmail }),
				reviewUser.collection("notes").doc("note").set({ title: "review" }),
				reviewUser
					.collection("devices")
					.doc("device")
					.set({ publicKey: "review" }),
				otherUser.set({ email: `other-${suffix}@example.com` }),
				otherUser.collection("notes").doc("note").set({ title: "other" }),
				reviewSubscription.set({ userId: reviewUid }),
				otherSubscription.set({ userId: otherUid }),
				reviewPayment.set({ userId: reviewUid }),
				reviewLinkSession.set({ uid: reviewUid }),
				reviewOAuthState.set({ linkingUserId: reviewUid }),
				reviewOAuthCompletion.set({ uid: reviewUid }),
				reviewShare.set({ owner_uid: reviewUid }),
				reviewShare
					.collection("requests")
					.doc("request")
					.set({ requester_uid: otherUid }),
				otherShare.set({ owner_uid: otherUid }),
				otherShare
					.collection("requests")
					.doc("request")
					.set({ requester_uid: reviewUid }),
				reviewTrialUsage.set({ used: true }),
				reviewPasswordReset.set({ otp: "stale" }),
				reviewUserFile.save("review user attachment"),
				reviewShareFile.save("review share attachment"),
				otherUserFile.save("other user attachment"),
				otherShareFile.save("other share attachment"),
			]);

			const result = await cleanupReviewAccountData({
				db,
				bucket,
				uid: reviewUid,
				email: reviewEmail.toUpperCase(),
			});

			assert.deepEqual(result, {
				deletedSubscriptions: 1,
				deletedPayments: 1,
				deletedShares: 1,
				deletedAccountLinkSessions: 1,
				deletedOAuthStates: 1,
				deletedOAuthCompletions: 1,
				deletedUserStorageFiles: 1,
				deletedShareStorageFiles: 1,
			});

			const [
				reviewUserSnapshot,
				reviewNoteSnapshot,
				reviewDeviceSnapshot,
				reviewSubscriptionSnapshot,
				reviewPaymentSnapshot,
				reviewLinkSessionSnapshot,
				reviewOAuthStateSnapshot,
				reviewOAuthCompletionSnapshot,
				reviewShareSnapshot,
				reviewRequestSnapshot,
				reviewTrialUsageSnapshot,
				reviewPasswordResetSnapshot,
				[reviewUserFileExists],
				[reviewShareFileExists],
				otherUserSnapshot,
				otherNoteSnapshot,
				otherSubscriptionSnapshot,
				otherShareSnapshot,
				otherRequestSnapshot,
				[otherUserFileExists],
				[otherShareFileExists],
			] = await Promise.all([
				reviewUser.get(),
				reviewUser.collection("notes").doc("note").get(),
				reviewUser.collection("devices").doc("device").get(),
				reviewSubscription.get(),
				reviewPayment.get(),
				reviewLinkSession.get(),
				reviewOAuthState.get(),
				reviewOAuthCompletion.get(),
				reviewShare.get(),
				reviewShare.collection("requests").doc("request").get(),
				reviewTrialUsage.get(),
				reviewPasswordReset.get(),
				reviewUserFile.exists(),
				reviewShareFile.exists(),
				otherUser.get(),
				otherUser.collection("notes").doc("note").get(),
				otherSubscription.get(),
				otherShare.get(),
				otherShare.collection("requests").doc("request").get(),
				otherUserFile.exists(),
				otherShareFile.exists(),
			]);

			assert.equal(reviewUserSnapshot.exists, false);
			assert.equal(reviewNoteSnapshot.exists, false);
			assert.equal(reviewDeviceSnapshot.exists, false);
			assert.equal(reviewSubscriptionSnapshot.exists, false);
			assert.equal(reviewPaymentSnapshot.exists, false);
			assert.equal(reviewLinkSessionSnapshot.exists, false);
			assert.equal(reviewOAuthStateSnapshot.exists, false);
			assert.equal(reviewOAuthCompletionSnapshot.exists, false);
			assert.equal(reviewShareSnapshot.exists, false);
			assert.equal(reviewRequestSnapshot.exists, false);
			assert.equal(reviewTrialUsageSnapshot.exists, false);
			assert.equal(reviewPasswordResetSnapshot.exists, false);
			assert.equal(reviewUserFileExists, false);
			assert.equal(reviewShareFileExists, false);

			assert.equal(otherUserSnapshot.exists, true);
			assert.equal(otherNoteSnapshot.exists, true);
			assert.equal(otherSubscriptionSnapshot.exists, true);
			assert.equal(otherShareSnapshot.exists, true);
			assert.equal(otherRequestSnapshot.exists, true);
			assert.equal(otherUserFileExists, true);
			assert.equal(otherShareFileExists, true);
		} finally {
			await Promise.all([
				db.recursiveDelete(reviewUser),
				db.recursiveDelete(otherUser),
				db.recursiveDelete(reviewSubscription),
				db.recursiveDelete(otherSubscription),
				db.recursiveDelete(reviewPayment),
				db.recursiveDelete(reviewLinkSession),
				db.recursiveDelete(reviewOAuthState),
				db.recursiveDelete(reviewOAuthCompletion),
				db.recursiveDelete(reviewShare),
				db.recursiveDelete(otherShare),
				reviewTrialUsage.delete(),
				reviewPasswordReset.delete(),
				reviewUserFile.delete({ ignoreNotFound: true }),
				reviewShareFile.delete({ ignoreNotFound: true }),
				otherUserFile.delete({ ignoreNotFound: true }),
				otherShareFile.delete({ ignoreNotFound: true }),
			]).catch(() => {});
			await app.delete();
		}
	},
);
