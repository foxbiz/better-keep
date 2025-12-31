import * as crypto from "node:crypto";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db, emailPassword, razorpayKeySecret } from "../config";
import { sendRazorpaySubscriptionEmail, setSubscriptionClaims } from "../utils";

/**
 * Verify Razorpay subscription payment
 * Called after successful payment on client
 */
export default onCall(
	{
		secrets: [razorpayKeySecret, emailPassword],
	},
	async (
		request: CallableRequest<{
			subscriptionId: string;
			paymentId: string;
			signature: string;
		}>,
	) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;
		const { subscriptionId, paymentId, signature } = request.data;

		console.log(
			`Verifying Razorpay subscription ${subscriptionId} for user ${userId}`,
		);

		try {
			const keySecret = razorpayKeySecret.value().trim();

			// Verify signature
			const expectedSignature = crypto
				.createHmac("sha256", keySecret)
				.update(`${paymentId}|${subscriptionId}`)
				.digest("hex");

			if (signature !== expectedSignature) {
				console.error("Invalid Razorpay signature");
				throw new HttpsError("invalid-argument", "Invalid payment signature");
			}

			// Get payment details from Firebase
			const paymentDoc = await db
				.collection("payments")
				.doc(subscriptionId)
				.get();

			if (!paymentDoc.exists) {
				throw new HttpsError("not-found", "Payment not found");
			}

			const paymentData = paymentDoc.data();
			if (!paymentData) {
				throw new HttpsError("not-found", "Payment data not found");
			}

			if (paymentData.userId !== userId) {
				throw new HttpsError(
					"permission-denied",
					"Payment does not belong to user",
				);
			}

			// Calculate expiry based on plan
			const now = new Date();
			const expiryDate = new Date(now);
			if (paymentData.plan === "yearly") {
				expiryDate.setFullYear(expiryDate.getFullYear() + 1);
			} else {
				expiryDate.setMonth(expiryDate.getMonth() + 1);
			}

			// Update payment status
			await paymentDoc.ref.update({
				status: "verified",
				razorpayPaymentId: paymentId,
				razorpaySignature: signature,
				verifiedAt: FieldValue.serverTimestamp(),
			});

			// Activate subscription for user
			await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.set({
					plan: "pro",
					source: "razorpay",
					razorpaySubscriptionId: subscriptionId,
					razorpayPaymentId: paymentId,
					billingPeriod: paymentData.plan,
					startDate: Timestamp.now(),
					expiryDate: Timestamp.fromDate(expiryDate),
					autoRenew: true,
					subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
					updatedAt: FieldValue.serverTimestamp(),
				});

			// Set custom claims for server-side enforcement
			await setSubscriptionClaims(userId, "pro", expiryDate);

			console.log(
				`Activated subscription for user ${userId}, expires ${expiryDate.toISOString()}`,
			);

			// Send welcome email
			await sendRazorpaySubscriptionEmail(userId, "welcome", expiryDate);

			return { success: true, expiryDate: expiryDate.toISOString() };
		} catch (error) {
			console.error("Error verifying Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to verify subscription");
		}
	},
);
