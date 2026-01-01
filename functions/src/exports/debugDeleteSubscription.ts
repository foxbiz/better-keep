import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db } from "../config";

/**
 * DEBUG ONLY: Delete subscription for testing
 * This immediately removes the subscription from Firestore
 * Only available in emulator environment
 */
export default onCall(
	async (request: CallableRequest<Record<string, never>>) => {
		// Only allow in emulator
		if (!process.env.FUNCTIONS_EMULATOR) {
			throw new HttpsError(
				"failed-precondition",
				"This function is only available in development",
			);
		}

		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;

		console.log(`DEBUG: Deleting subscription for user ${userId}`);

		try {
			// Delete the subscription document
			await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.delete();

			console.log(`DEBUG: Deleted subscription for user ${userId}`);

			return { success: true, message: "Subscription deleted for testing" };
		} catch (error) {
			console.error("Error deleting subscription:", error);
			throw new HttpsError("internal", "Failed to delete subscription");
		}
	},
);
