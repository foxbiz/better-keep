import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { auth, db, emailPassword, googlePlayCredentials } from "../config";
import {
	formatEmailDate,
	generateTransactionalEmail,
} from "../email_templates";
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
							...generateTransactionalEmail({
								title: "Your subscription is ending soon",
								category: "Subscription",
								paragraphs: [
									"Your Better Keep Pro subscription is due to expire. To keep unlimited locked notes and cloud sync, check that auto-renewal is enabled or resubscribe.",
								],
								details: [
									{
										label: "Expiry date",
										value: formatEmailDate(expiresAt),
									},
								],
								action: { label: "Manage subscription", url: manageUrl },
							}),
						});

						console.log("Sent subscription expiry warning");
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
