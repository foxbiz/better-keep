import { FieldValue } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db, emailPassword, razorpayKeyId, razorpayKeySecret } from "../config";
import { razorpayRequest, sendRazorpaySubscriptionEmail } from "../utils";

/**
 * Cancel a Razorpay subscription
 */
export default onCall(
	{
		secrets: [razorpayKeyId, razorpayKeySecret, emailPassword],
	},
	async (request: CallableRequest<Record<string, never>>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;

		console.log(`Cancelling Razorpay subscription for user ${userId}`);

		try {
			const keyId = razorpayKeyId.value().trim();
			const keySecret = razorpayKeySecret.value().trim();

			// Get user's subscription
			const subDoc = await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.get();

			if (!subDoc.exists) {
				throw new HttpsError("not-found", "No active subscription found");
			}

			const subData = subDoc.data();

			if (subData?.source !== "razorpay" || !subData.razorpaySubscriptionId) {
				throw new HttpsError(
					"failed-precondition",
					"Subscription was not purchased via Razorpay",
				);
			}

			// Get actual subscription status from Razorpay first
			const razorpaySub = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/subscriptions/${subData.razorpaySubscriptionId}`,
			)) as { status: string };

			console.log(`Razorpay subscription status: ${razorpaySub.status}`);

			// Determine cancel mode based on subscription state
			// For subscriptions not yet in active billing cycle, cancel immediately
			// For active subscriptions, cancel at end of cycle
			const cancelImmediately =
				razorpaySub.status === "created" ||
				razorpaySub.status === "authenticated" ||
				razorpaySub.status === "pending";

			// Cancel subscription in Razorpay
			await razorpayRequest(
				keyId,
				keySecret,
				"POST",
				`/subscriptions/${subData.razorpaySubscriptionId}/cancel`,
				cancelImmediately
					? { cancel_at_cycle_end: 0 }
					: { cancel_at_cycle_end: 1 },
			);

			// Update subscription status
			if (cancelImmediately) {
				// Subscription cancelled immediately - delete it
				await subDoc.ref.delete();
				console.log(
					`Immediately cancelled and removed subscription for user ${userId}`,
				);
			} else {
				// Subscription cancelled at cycle end - mark as cancelled
				await subDoc.ref.update({
					autoRenew: false,
					subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
					cancelledAt: FieldValue.serverTimestamp(),
					updatedAt: FieldValue.serverTimestamp(),
				});
				console.log(`Cancelled subscription for user ${userId} at cycle end`);
			}

			// Send cancellation email
			await sendRazorpaySubscriptionEmail(
				userId,
				"cancelled",
				cancelImmediately ? null : subData.expiryDate?.toDate(),
			);

			return { success: true, immediate: cancelImmediately };
		} catch (error) {
			console.error("Error cancelling Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to cancel subscription");
		}
	},
);
