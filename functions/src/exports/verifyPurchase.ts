import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, emailPassword, googlePlayCredentials } from "../config";
import type { VerifyPurchaseRequest } from "../types";
import {
	getEmailTransporter,
	sendEmail,
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
export default onCall(
	{ secrets: [googlePlayCredentials, emailPassword] },
	async (request: CallableRequest<VerifyPurchaseRequest>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be signed in");
		}

		const userId = request.auth.uid;
		const { productId, purchaseToken, source } = request.data;

		if (!productId || !purchaseToken || !source) {
			throw new HttpsError("invalid-argument", "Missing required fields");
		}

		console.log(
			`Verifying purchase for user ${userId}: ${productId} (${source})`,
		);

		try {
			let result: { valid: boolean; message: string; subscription?: object };

			if (source === "play_store") {
				result = await verifyGooglePlayPurchase(
					userId,
					productId,
					purchaseToken,
				);
			} else if (source === "app_store") {
				// TODO: Implement App Store verification
				throw new HttpsError(
					"unimplemented",
					"App Store verification not yet implemented",
				);
			} else {
				throw new HttpsError("invalid-argument", "Invalid source");
			}

			// Send welcome email if verification was successful
			if (result.valid) {
				await sendSubscriptionWelcomeEmail(userId, result.subscription);
			}

			return result;
		} catch (error) {
			console.error(`Error verifying purchase for ${userId}:`, error);

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

		const transporter = getEmailTransporter(emailPassword.value());
		const senderEmail = process.env.EMAIL_FROM;
		const senderName = process.env.EMAIL_NAME;

		const subData = subscription as
			| { plan?: string; billingPeriod?: string; expiresAt?: string }
			| undefined;
		const billingPeriod = subData?.billingPeriod || "monthly";
		const expiresAt = subData?.expiresAt
			? new Date(subData.expiresAt).toLocaleDateString()
			: "N/A";

		const htmlContent = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
        <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
          <div style="text-align: center; margin-bottom: 24px;">
            <img src="https://betterkeep.app/icons/logo.png" alt="Better Keep Notes" style="width: 64px; height: 64px;">
          </div>
          <h1 style="color: #333; font-size: 22px; margin-bottom: 20px;">Welcome to <strong>Better Keep Notes</strong> Pro</h1>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            Hi there,
          </p>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            Thank you for subscribing to <strong>Better Keep Notes Pro</strong>. Your payment has been processed and your account has been upgraded.
          </p>
          <div style="background: #f8f9fa; border-radius: 8px; padding: 16px; margin: 20px 0; border-left: 3px solid #6366f1;">
            <p style="color: #333; font-size: 15px; margin: 0 0 8px 0; font-weight: 600;">Subscription Details</p>
            <p style="color: #555; font-size: 15px; margin: 4px 0;">Plan: <strong>Pro ${
							billingPeriod === "yearly" ? "(Yearly)" : "(Monthly)"
						}</strong></p>
            <p style="color: #555; font-size: 15px; margin: 4px 0;">Next billing date: <strong>${expiresAt}</strong></p>
          </div>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 12px;">
            With your Pro subscription, you now have access to:
          </p>
          <ul style="color: #555; font-size: 15px; line-height: 1.8; padding-left: 20px; margin-bottom: 16px;">
            <li>Unlimited locked notes with biometric protection</li>
            <li>Real-time end-to-end encrypted cloud sync</li>
            <li>Priority support</li>
          </ul>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            If you have any questions about your subscription or need help getting started, contact us at <a href="mailto:support@betterkeep.app" style="color: #6366f1;">support@betterkeep.app</a>.
          </p>
          <p style="color: #555; font-size: 15px; line-height: 1.6;">
            Thanks again for your support.
          </p>
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 13px;">
            <strong>Better Keep Notes</strong> by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `;

		await sendEmail(transporter, {
			from: `"${senderName}" <${senderEmail}>`,
			to: email,
			subject: "Your Better Keep Notes Pro subscription is now active",
			html: htmlContent,
			text: `Hi there,\n\nThank you for subscribing to Better Keep Notes Pro. Your payment has been processed and your account has been upgraded.\n\nSubscription Details:\nPlan: Pro (${billingPeriod})\nNext billing date: ${expiresAt}\n\nWith your Pro subscription, you now have access to unlimited locked notes with biometric protection, real-time end-to-end encrypted cloud sync, and priority support.\n\nIf you have any questions, contact us at support@betterkeep.app.\n\nThanks again for your support.\n\nBetter Keep Notes by Foxbiz Software Pvt. Ltd.`,
		});

		console.log(`Sent welcome email to ${email}`);
	} catch (error) {
		console.error(`Failed to send welcome email to user ${userId}:`, error);
		// Don't throw - email failure shouldn't fail the purchase
	}
}
