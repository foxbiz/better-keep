import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, isEmulator } from "../config";
import { mergeSubscriptionClaims } from "../customClaims";
import { isReviewAccountEmail, REVIEW_ACCESS_CLAIM } from "../reviewAccess";

/**
 * Sets test Pro claims for authenticated users in the Firebase Auth Emulator.
 *
 * This function is ONLY available when running in the Firebase Emulator.
 * It bypasses the normal subscription flow to allow testing Pro features.
 *
 * The beforeUserSignedIn blocking function doesn't trigger in the Auth Emulator,
 * so this callable function provides a way to manually set the required custom claims.
 */
export default onCall(async (request) => {
	// Only allow in emulator mode
	if (!isEmulator) {
		throw new HttpsError(
			"failed-precondition",
			"This function is only available in the Firebase Emulator",
		);
	}

	// Require authentication
	if (!request.auth?.uid) {
		throw new HttpsError("unauthenticated", "Must be authenticated");
	}

	const uid = request.auth.uid;

	// Set Pro claims that expire in 30 days
	const expiresAt = Date.now() + 30 * 24 * 60 * 60 * 1000;
	const user = await auth.getUser(uid);

	const claims = mergeSubscriptionClaims(
		user.customClaims,
		"pro",
		new Date(expiresAt),
	);
	if (isReviewAccountEmail(user.email)) {
		claims[REVIEW_ACCESS_CLAIM] = true;
	}
	await auth.setCustomUserClaims(uid, claims);

	console.log(
		`[Emulator] Set Pro claims for user ${uid}, expires ${new Date(expiresAt).toISOString()}`,
	);

	return {
		success: true,
		plan: "pro",
		planExpiresAt: expiresAt,
	};
});
