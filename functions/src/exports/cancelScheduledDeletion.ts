import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import { cancelDeletion } from "../accountDeletionLifecycle";
import { db } from "../config";
import { onNonReviewCall } from "../nonReviewCallable";

/**
 * HTTP Callable function to cancel a scheduled deletion
 * Called when user signs back in before the 30-day grace period ends
 */
export default onNonReviewCall({}, async (request: CallableRequest) => {
	console.log("cancelScheduledDeletion called");

	// Ensure user is authenticated
	if (!request.auth) {
		console.log("cancelScheduledDeletion: No auth context");
		throw new HttpsError(
			"unauthenticated",
			"User must be signed in to cancel deletion",
		);
	}
	const userId = request.auth.uid;
	console.log(`cancelScheduledDeletion: Processing for user ${userId}`);

	try {
		const wasScheduled = await cancelDeletion(
			db,
			userId,
			"cancelScheduledDeletion",
		);
		if (!wasScheduled) {
			return {
				success: true,
				message: "No scheduled deletion to cancel",
				wasScheduled: false,
			};
		}
		console.log(`Cancelled scheduled deletion for user: ${userId}`);
		// The audit transition sends a notice even when sign-in cancelled first.

		return {
			success: true,
			message: "Account deletion cancelled successfully",
			wasScheduled: true,
		};
	} catch (error) {
		console.error(`Error cancelling deletion for ${userId}:`, error);

		if (error instanceof HttpsError) {
			throw error;
		}

		throw new HttpsError("internal", "Failed to cancel account deletion");
	}
});
