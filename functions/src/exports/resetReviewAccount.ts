import { onCall } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import { REVIEW_ACCOUNT_EMAIL, auth, db } from "../config";
import { setSubscriptionClaims } from "../utils";

/**
 * Reset the review account's subscription.
 * Deletes the subscription doc, clears custom claims, and removes
 * related entries from the global subscriptions collection.
 *
 * Can be invoked from the Firebase Console (Functions → resetReviewAccount → Test)
 * or via any authenticated call. Only operates on the hard-coded review account.
 */
export default onCall(async () => {
	// Look up review account by email
	let reviewUser;
	try {
		reviewUser = await auth.getUserByEmail(REVIEW_ACCOUNT_EMAIL);
	} catch {
		throw new HttpsError(
			"not-found",
			`Review account ${REVIEW_ACCOUNT_EMAIL} not found`,
		);
	}

	const userId = reviewUser.uid;
	console.log(`Resetting review account: ${userId} (${REVIEW_ACCOUNT_EMAIL})`);

	const batch = db.batch();

	// 1. Delete user subscription doc
	const userSubRef = db
		.collection("users")
		.doc(userId)
		.collection("subscription")
		.doc("status");
	batch.delete(userSubRef);

	// 2. Delete any linked entries in global subscriptions collection
	const linkedSubs = await db
		.collection("subscriptions")
		.where("userId", "==", userId)
		.get();
	for (const doc of linkedSubs.docs) {
		batch.delete(doc.ref);
	}

	await batch.commit();

	// 3. Clear custom claims to free
	await setSubscriptionClaims(userId, "free", null);

	console.log(`Review account ${userId} has been reset to free`);

	return {
		success: true,
		message: `Review account (${REVIEW_ACCOUNT_EMAIL}) reset to free plan`,
		userId,
	};
});
