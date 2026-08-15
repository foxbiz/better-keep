import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { auth, db, emailPassword, googlePlayCredentials } from "../config";
import {
	endUnqueryableGooglePlaySubscription,
	isGooglePlayGoneError,
	refreshGooglePlaySubscription,
} from "../googlePlayService";
import { reconcileUserEntitlement } from "../subscriptionReconciler";
import { sendEmail } from "../utils";

/**
 * Scheduled function to check for expired subscriptions and notify users
 * Runs daily at 9:00 AM UTC
 */
export default onSchedule(
	{
		schedule: "0 9 * * *",
		secrets: [emailPassword, googlePlayCredentials],
	},
	async () => {
		console.log("Running expired subscription check...");

		try {
			const now = Timestamp.now();
			const oneDayFromNow = Timestamp.fromMillis(
				Date.now() + 24 * 60 * 60 * 1000,
			);

			// Find subscriptions expiring within 24 hours that haven't been notified
			const expiringSubsSnapshot = await db
				.collection("subscriptions")
				.where("expiresAt", ">", now)
				.where("expiresAt", "<", oneDayFromNow)
				.where("expiryNotificationSent", "!=", true)
				.get();

			console.log(
				`Found ${expiringSubsSnapshot.size} subscriptions expiring soon`,
			);

			for (const doc of expiringSubsSnapshot.docs) {
				const subData = doc.data();
				const userId = subData.userId;
				const expiresAt = subData.expiresAt?.toDate();
				const source = subData.source;

				if (!userId || !expiresAt) continue;

				try {
					// Get user email
					const userRecord = await auth.getUser(userId);
					const email = userRecord.email;

					if (email) {
						const senderEmail = process.env.EMAIL_FROM;
						const senderName = process.env.EMAIL_NAME;
						const manageUrl =
							source === "app_store"
								? "https://apps.apple.com/account/subscriptions"
								: "https://play.google.com/store/account/subscriptions";

						await sendEmail({
							from: `"${senderName}" <${senderEmail}>`,
							to: email,
							subject: "Your Better Keep Pro subscription is expiring soon",
							html: `
                <!DOCTYPE html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1.0">
                </head>
                <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
                  <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
                    <h1 style="color: #333; font-size: 24px; margin-bottom: 16px;">Subscription Expiring Soon</h1>
                    <p style="color: #666; font-size: 16px; line-height: 1.5;">
                      Your Better Keep Pro subscription will expire on <strong>${expiresAt.toLocaleDateString()}</strong>.
                    </p>
                    <p style="color: #666; font-size: 16px; line-height: 1.5;">
                      To continue enjoying unlimited locked notes and cloud sync, make sure your subscription auto-renews or resubscribe.
                    </p>
                    <div style="margin: 24px 0;">
							<a href="${manageUrl}" style="display: inline-block; background: #6366f1; color: white; padding: 12px 24px; border-radius: 8px; text-decoration: none; font-weight: 600;">
                        Manage Subscription
                      </a>
                    </div>
                    <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
                    <p style="color: #999; font-size: 12px;">
                      If you have questions, contact us at support@betterkeep.app
                    </p>
                    <p style="color: #bbb; font-size: 11px; margin-top: 8px;">
                      Better Keep by Foxbiz Software Pvt. Ltd.
                    </p>
                  </div>
                </body>
                </html>
              `,
							text: `Your Better Keep Pro subscription will expire on ${expiresAt.toLocaleDateString()}. To continue enjoying Pro features, make sure your subscription auto-renews.`,
						});

						console.log(`Sent expiry warning to ${email}`);
					}

					// Mark as notified
					await doc.ref.update({
						expiryNotificationSent: true,
						expiryNotificationSentAt: FieldValue.serverTimestamp(),
					});
				} catch (userError) {
					console.error(
						`Failed to process expiring sub for user ${userId}:`,
						userError,
					);
				}
			}

			// Also update expired subscriptions (disable features)
			const expiredSubsSnapshot = await db
				.collection("subscriptions")
				.where("expiresAt", "<", now)
				.where("source", "in", ["play_store", "app_store"])
				.get();

			console.log(
				`Found ${expiredSubsSnapshot.size} expired subscriptions to update`,
			);

			for (const doc of expiredSubsSnapshot.docs) {
				const subData = doc.data();
				const userId = subData.userId;
				const source = subData.source;
				try {
					if (source === "play_store") {
						try {
							await refreshGooglePlaySubscription({
								purchaseToken:
									typeof subData.purchaseToken === "string"
										? subData.purchaseToken
										: doc.id,
							});
							continue;
						} catch (error) {
							if (!isGooglePlayGoneError(error)) throw error;
							await endUnqueryableGooglePlaySubscription(
								typeof subData.purchaseToken === "string"
									? subData.purchaseToken
									: doc.id,
							);
							continue;
						}
					}
					await doc.ref.update({
						subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
						entitlementState: "ended",
						willAutoRenew: false,
						updatedAt: FieldValue.serverTimestamp(),
					});
					await reconcileUserEntitlement(userId);
					console.log(`Reconciled expired subscription for user ${userId}`);
				} catch (updateError) {
					console.error(
						`Failed to update expired sub for user ${userId}:`,
						updateError,
					);
				}
			}

			console.log("Expired subscription check completed");
		} catch (error) {
			console.error("Error in expired subscription check:", error);
		}
	},
);
