import * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db, emailPassword, razorpayKeyId, razorpayKeySecret } from "../config";
import { razorpayRequest, sendRazorpaySubscriptionEmail } from "../utils";

/**
 * Resume a cancelled Razorpay subscription
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

		console.log(`Resuming Razorpay subscription for user ${userId}`);

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
				throw new HttpsError("not-found", "No subscription found");
			}

			const subData = subDoc.data();

			if (subData?.source !== "razorpay" || !subData.razorpaySubscriptionId) {
				throw new HttpsError(
					"failed-precondition",
					"Subscription was not purchased via Razorpay",
				);
			}

			// Check if subscription is actually cancelled in our records
			if (subData.subscriptionState !== "SUBSCRIPTION_STATE_CANCELED") {
				throw new HttpsError(
					"failed-precondition",
					"Subscription is not in cancelled state",
				);
			}

			// Get actual subscription status from Razorpay
			const razorpaySub = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/subscriptions/${subData.razorpaySubscriptionId}`,
			)) as { status: string };

			console.log(`Razorpay subscription status: ${razorpaySub.status}`);

			// Handle based on actual Razorpay status
			if (razorpaySub.status === "active") {
				// Subscription is still active in Razorpay (cancel_at_cycle_end was set)
				// Unfortunately, Razorpay doesn't support undoing cancel_at_cycle_end
				// The user needs to create a new subscription when this one expires
				throw new HttpsError(
					"failed-precondition",
					"Cannot resume a subscription that was cancelled at cycle end. " +
						"Your current subscription will remain active until it expires. " +
						"You can subscribe again after it expires.",
				);
			} else if (
				razorpaySub.status === "halted" ||
				razorpaySub.status === "paused"
			) {
				// Subscription can be resumed
				await razorpayRequest(
					keyId,
					keySecret,
					"POST",
					`/subscriptions/${subData.razorpaySubscriptionId}/resume`,
					{ resume_at: "now" },
				);

				// Update subscription status
				await subDoc.ref.update({
					autoRenew: true,
					subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
					cancelledAt: admin.firestore.FieldValue.delete(),
					updatedAt: FieldValue.serverTimestamp(),
				});

				console.log(`Resumed subscription for user ${userId}`);

				// Send resume email
				await sendRazorpaySubscriptionEmail(
					userId,
					"resumed",
					subData.expiryDate?.toDate(),
				);

				return { success: true };
			} else if (razorpaySub.status === "cancelled") {
				// Subscription is fully cancelled in Razorpay - can't resume
				throw new HttpsError(
					"failed-precondition",
					"This subscription has been fully cancelled and cannot be resumed. " +
						"Please create a new subscription.",
				);
			} else {
				throw new HttpsError(
					"failed-precondition",
					`Subscription is in '${razorpaySub.status}' state and cannot be resumed.`,
				);
			}
		} catch (error) {
			console.error("Error resuming Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to resume subscription");
		}
	},
);
