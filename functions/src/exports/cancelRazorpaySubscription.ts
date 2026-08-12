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
 * Cancel a Razorpay subscription
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

		console.log(`Cancelling Razorpay subscription for user ${userId}`);

		try {
			const keyId = razorpayKeyId.value().trim();
			const keySecret = razorpayKeySecret.value().trim();

			// Get user's subscription
			const provider = await findUserRazorpaySubscription(userId);

			if (!provider) {
				throw new HttpsError("not-found", "No active subscription found");
			}

			const subData = provider.data;
			const subscriptionId = subData.providerSubscriptionId;

			if (typeof subscriptionId !== "string") {
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
				`/subscriptions/${subscriptionId}`,
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
				`/subscriptions/${subscriptionId}/cancel`,
				cancelImmediately
					? { cancel_at_cycle_end: 0 }
					: { cancel_at_cycle_end: 1 },
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

			// Send cancellation email
			const expiryDate = (
				normalized.expiresAt as { toDate?: () => Date } | undefined
			)?.toDate?.();
			try {
				await sendRazorpaySubscriptionEmail(
					userId,
					"cancelled",
					cancelImmediately ? null : expiryDate,
				);
			} catch (emailError) {
				console.error(
					`Subscription cancelled, but cancellation email failed for ${userId}:`,
					emailError,
				);
			}

			return { success: true, immediate: cancelImmediately };
		} catch (error) {
			console.error("Error cancelling Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to cancel subscription");
		}
	},
);
