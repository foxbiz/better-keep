import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import { emailPassword, razorpayKeyId, razorpayKeySecret } from "../config";
import { onNonReviewCall } from "../nonReviewCallable";
import {
	findUserRazorpaySubscription,
	refreshRazorpaySubscriptionRecord,
} from "../razorpayService";
import { razorpayRequest, sendRazorpaySubscriptionEmail } from "../utils";

/**
 * Resume a cancelled Razorpay subscription
 */
export default onNonReviewCall(
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
			const provider = await findUserRazorpaySubscription(userId);

			if (!provider) {
				throw new HttpsError("not-found", "No subscription found");
			}

			const subData = provider.data;
			const subscriptionId = subData.providerSubscriptionId;

			if (typeof subscriptionId !== "string") {
				throw new HttpsError(
					"failed-precondition",
					"Subscription was not purchased via Razorpay",
				);
			}

			// Check if subscription is actually cancelled in our records
			if (
				![
					"CANCELED",
					"CANCELLED",
					"SUBSCRIPTION_STATE_CANCELED",
					"HALTED",
					"PAUSED",
				].includes(String(subData.subscriptionState ?? "").toUpperCase())
			) {
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
				`/subscriptions/${subscriptionId}`,
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
			}

			if (razorpaySub.status === "halted" || razorpaySub.status === "paused") {
				// Subscription can be resumed
				await razorpayRequest(
					keyId,
					keySecret,
					"POST",
					`/subscriptions/${subscriptionId}/resume`,
					{ resume_at: "now" },
				);

				const normalized = await refreshRazorpaySubscriptionRecord({
					billingPeriod:
						typeof subData.billingPeriod === "string"
							? subData.billingPeriod
							: null,
					keyId,
					keySecret,
					subscriptionId,
					userId,
				});

				console.log(`Resumed subscription for user ${userId}`);

				// Send resume email
				const expiryDate = (
					normalized.expiresAt as { toDate?: () => Date } | undefined
				)?.toDate?.();
				try {
					await sendRazorpaySubscriptionEmail(userId, "resumed", expiryDate);
				} catch (emailError) {
					console.error(
						`Subscription resumed, but resume email failed for ${userId}:`,
						emailError,
					);
				}

				return { success: true };
			}

			if (razorpaySub.status === "cancelled") {
				// Subscription is fully cancelled in Razorpay - can't resume
				throw new HttpsError(
					"failed-precondition",
					"This subscription has been fully cancelled and cannot be resumed. " +
						"Please create a new subscription.",
				);
			}

			throw new HttpsError(
				"failed-precondition",
				`Subscription is in '${razorpaySub.status}' state and cannot be resumed.`,
			);
		} catch (error) {
			console.error("Error resuming Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to resume subscription");
		}
	},
);
