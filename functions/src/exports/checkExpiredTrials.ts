import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { db, emailPassword } from "../config";
import {
	getEmailTransporter,
	sendEmail,
	setSubscriptionClaims,
} from "../utils";

/**
 * Scheduled function to check for expired trials and send notification emails.
 * Runs every hour to check for trials expiring soon or just expired.
 */
export default onSchedule(
	{
		schedule: "every 1 hours",
		secrets: [emailPassword],
	},
	async () => {
		console.log("Checking for expired trials...");

		try {
			const now = new Date();

			// Find trials that expired in the last hour and haven't been notified
			const oneHourAgo = new Date(now.getTime() - 60 * 60 * 1000);

			const expiredTrials = await db
				.collection("trialUsage")
				.where("trialExpiresAt", "<=", Timestamp.fromDate(now))
				.where("trialExpiresAt", ">", Timestamp.fromDate(oneHourAgo))
				.where("expiryEmailSent", "==", false)
				.get();

			// Also check trials without the expiryEmailSent field (legacy)
			const expiredTrialsLegacy = await db
				.collection("trialUsage")
				.where("trialExpiresAt", "<=", Timestamp.fromDate(now))
				.where("trialExpiresAt", ">", Timestamp.fromDate(oneHourAgo))
				.get();

			const allExpired = new Map<
				string,
				FirebaseFirestore.QueryDocumentSnapshot
			>();
			for (const doc of expiredTrials.docs) {
				allExpired.set(doc.id, doc);
			}
			for (const doc of expiredTrialsLegacy.docs) {
				const data = doc.data();
				if (data.expiryEmailSent !== true) {
					allExpired.set(doc.id, doc);
				}
			}

			console.log(`Found ${allExpired.size} expired trials to notify`);

			for (const [, doc] of allExpired) {
				const data = doc.data();
				const email = data.email;
				const userId = data.userId;

				if (!email || email === "unknown") continue;

				try {
					// Update subscription status to expired
					const userRef = db.collection("users").doc(userId);
					const subscriptionRef = userRef
						.collection("subscription")
						.doc("status");
					const subscriptionDoc = await subscriptionRef.get();

					if (
						subscriptionDoc.exists &&
						subscriptionDoc.data()?.source === "trial"
					) {
						await subscriptionRef.update({
							status: "expired",
							plan: "free",
							updatedAt: Timestamp.now(),
						});

						// Clear custom claims
						await setSubscriptionClaims(userId, "free", null);
					}

					// Send trial expired email
					await sendTrialExpiredEmail(email, data.displayName || "there");
					console.log(`Sent trial expired email to ${email}`);

					// Mark as notified
					await doc.ref.update({
						expiryEmailSent: true,
						expiryEmailSentAt: Timestamp.now(),
					});
				} catch (emailError) {
					console.error(
						`Failed to process expired trial for ${email}:`,
						emailError,
					);
				}
			}

			console.log("Expired trial check completed");
		} catch (error) {
			console.error("Error checking expired trials:", error);
		}
	},
);
/**
 * Send trial expired email
 */
async function sendTrialExpiredEmail(
	email: string,
	displayName: string,
): Promise<void> {
	const transporter = getEmailTransporter(emailPassword.value());
	const senderEmail = process.env.EMAIL_FROM;
	const senderName = process.env.EMAIL_NAME;

	const mailOptions = {
		from: `"${senderName}" <${senderEmail}>`,
		to: email,
		subject: "Your Better Keep Pro Trial Has Ended",
		html: `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
        <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
          <h1 style="color: #333; font-size: 24px; margin-bottom: 16px;">Your Pro Trial Has Ended</h1>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            Hi ${displayName},
          </p>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            Your Better Keep Pro trial has ended. We hope you enjoyed the premium features!
          </p>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            You can continue using Better Keep with the free plan, or upgrade to Pro to keep all the premium features:
          </p>
          <ul style="color: #333; font-size: 14px; line-height: 1.8;">
            <li>🔒 Unlimited locked notes</li>
            <li>☁️ Cloud sync across devices with end-to-end encryption</li>
          </ul>
          <div style="text-align: center; margin: 24px 0;">
            <a href="https://betterkeep.app/pricing" style="display: inline-block; background: linear-gradient(135deg, #6750A4 0%, #9C27B0 100%); color: white; text-decoration: none; padding: 14px 32px; border-radius: 8px; font-weight: 600; font-size: 16px;">
              Upgrade to Pro
            </a>
          </div>
          <p style="color: #666; font-size: 14px; line-height: 1.5;">
            Thank you for trying Better Keep Pro!
          </p>
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 12px;">
            Better Keep by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `,
		text: `
Your Better Keep Pro Trial Has Ended

Hi ${displayName},

Your Better Keep Pro trial has ended. We hope you enjoyed the premium features!

You can continue using Better Keep with the free plan, or upgrade to Pro to keep all the premium features:
- Unlimited locked notes
- Cloud sync across devices with end-to-end encryption

Upgrade at: https://betterkeep.app/pricing

Thank you for trying Better Keep Pro!

Better Keep by Foxbiz Software Pvt. Ltd.
    `,
	};

	await sendEmail(transporter, mailOptions);
}
