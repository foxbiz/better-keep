import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { db, emailPassword } from "../config";
import { generateTransactionalEmail } from "../email_templates";
import { reconcileUserEntitlement } from "../subscriptionReconciler";
import { sendEmail } from "../utils";

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
						await reconcileUserEntitlement(userId);
					}

					// Send trial expired email
					await sendTrialExpiredEmail(email, data.displayName || "there");
					console.log("Sent trial expired email");

					// Mark as notified
					await doc.ref.update({
						expiryEmailSent: true,
						expiryEmailSentAt: Timestamp.now(),
					});
				} catch (emailError) {
					console.error("Failed to process expired trial:", emailError);
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
	const senderEmail = process.env.EMAIL_FROM;
	const senderName = process.env.EMAIL_NAME;

	const mailOptions = {
		from: `"${senderName}" <${senderEmail}>`,
		to: email,
		subject: "Your Better Keep Pro Trial Has Ended",
		...generateTransactionalEmail({
			title: "Your Pro trial has ended",
			category: "Subscription",
			paragraphs: [
				`Hi ${displayName},`,
				"Your Better Keep Pro trial has ended. You can continue using the free plan, or upgrade to Pro to keep these features.",
			],
			list: {
				title: "With Better Keep Pro",
				items: [
					"Unlimited locked notes",
					"Cloud sync across devices with end-to-end encryption",
				],
			},
			action: {
				label: "View Pro plans",
				url: "https://betterkeep.app/pricing",
			},
		}),
	};

	await sendEmail(mailOptions);
}
