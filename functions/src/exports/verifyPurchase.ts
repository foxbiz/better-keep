import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import {
	appStoreSharedSecret,
	auth,
	emailPassword,
	googlePlayCredentials,
} from "../config";
import {
	formatEmailDate,
	generateTransactionalEmail,
} from "../email_templates";
import { onNonReviewCall } from "../nonReviewCallable";
import type { VerifyPurchaseRequest } from "../types";
import {
	sendEmail,
	verifyAppStorePurchase,
	verifyGooglePlayPurchase,
} from "../utils";

/**
 * Verify a purchase with Google Play and link it to the user's account.
 *
 * Security features:
 * - Verifies purchase with Google Play API
 * - Ensures one subscription = one account
 * - Handles app crash recovery
 * - Prevents fraud by server-side verification
 */
export default onNonReviewCall(
	{ secrets: [googlePlayCredentials, appStoreSharedSecret, emailPassword] },
	async (request: CallableRequest<VerifyPurchaseRequest>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be signed in");
		}
		const userId = request.auth.uid;
		const { productId, purchaseToken, source } = request.data;
		const verifyTraceId =
			typeof request.data.verifyTraceId === "string" &&
			request.data.verifyTraceId.trim().length > 0
				? request.data.verifyTraceId.trim()
				: "no-trace";

		if (!productId || !purchaseToken || !source) {
			throw new HttpsError("invalid-argument", "Missing required fields");
		}

		console.log(
			`[${verifyTraceId}] Verifying purchase for user ${userId}: ${productId} (${source})`,
		);

		try {
			let result: {
				valid: boolean;
				sendWelcomeEmail?: boolean;
				message: string;
				subscription?: object;
			};

			if (source === "play_store") {
				result = await verifyGooglePlayPurchase(
					userId,
					productId,
					purchaseToken,
				);
			} else if (source === "app_store") {
				result = await verifyAppStorePurchase(userId, productId, purchaseToken);
			} else {
				throw new HttpsError("invalid-argument", "Invalid source");
			}

			if (!result.valid) {
				console.warn(
					`[${verifyTraceId}] Purchase verification failed for user ${userId} (${source}): ${result.message}`,
				);
			}

			// Send welcome email only on first-time purchase (idempotency guard via Firestore flag)
			if (result.valid && result.sendWelcomeEmail !== false) {
				await sendSubscriptionWelcomeEmail(userId, result.subscription);
			}

			return result;
		} catch (error) {
			console.error(
				`[${verifyTraceId}] Error verifying purchase for ${userId}:`,
				error,
			);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to verify purchase");
		}
	},
);

/**
 * Send subscription welcome email to user after successful purchase
 */
async function sendSubscriptionWelcomeEmail(
	userId: string,
	subscription?: object,
): Promise<void> {
	try {
		const userRecord = await auth.getUser(userId);
		const email = userRecord.email;

		if (!email) {
			console.warn(`No email found for user ${userId}`);
			return;
		}

		const senderEmail = process.env.EMAIL_FROM;
		const senderName = process.env.EMAIL_NAME;

		const subData = subscription as
			| { plan?: string; billingPeriod?: string; expiresAt?: string }
			| undefined;
		const planName = subData?.plan === "lite" ? "Lite" : "Pro";
		const benefits =
			subData?.plan === "lite"
				? ["Automatic encrypted sync with your connected cloud storage"]
				: [
						"Unlimited locked notes with biometric protection",
						"Real-time end-to-end encrypted cloud sync",
						"Automatic encrypted sync with your connected cloud storage",
						"Priority support",
					];
		const billingPeriod = subData?.billingPeriod || "monthly";
		const expiresAt = subData?.expiresAt
			? formatEmailDate(new Date(subData.expiresAt))
			: "N/A";

		await sendEmail({
			from: `"${senderName}" <${senderEmail}>`,
			to: email,
			subject: `Your Better Keep Notes ${planName} subscription is now active`,
			...generateTransactionalEmail({
				title: `Your ${planName} plan is ready`,
				category: "Subscription",
				paragraphs: [
					`Thank you for subscribing to Better Keep Notes ${planName}. Your payment has been processed and your account has been upgraded.`,
				],
				details: [
					{
						label: "Plan",
						value: `${planName} (${billingPeriod === "yearly" ? "Yearly" : "Monthly"})`,
					},
					{ label: "Next billing date", value: expiresAt },
				],
				list: { title: "Included in your plan", items: benefits },
			}),
		});

		console.log("Sent subscription welcome email");
	} catch (error) {
		console.error(`Failed to send welcome email to user ${userId}:`, error);
		// Don't throw - email failure shouldn't fail the purchase
	}
}
