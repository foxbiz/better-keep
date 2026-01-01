import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import {
	ANDROID_PACKAGE_NAME,
	auth,
	db,
	emailPassword,
	googlePlayCredentials,
} from "../config";
import {
	getEmailTransporter,
	getPlayDeveloperApi,
	sendEmail,
	setSubscriptionClaims,
} from "../utils";

/**
 * Google Play Real-Time Developer Notifications (RTDN) webhook
 *
 * This handles subscription lifecycle events:
 * - Renewals
 * - Cancellations
 * - Expirations
 * - Grace period entries
 */
export default onRequest(
	{ secrets: [googlePlayCredentials, emailPassword] },
	async (req, res) => {
		if (req.method !== "POST") {
			res.status(405).send("Method not allowed");
			return;
		}

		try {
			// Google sends a Pub/Sub message with base64-encoded data
			const message = req.body?.message;
			if (!message?.data) {
				console.warn("Invalid webhook payload - no message data");
				res.status(400).send("Invalid payload");
				return;
			}

			const dataBuffer = Buffer.from(message.data, "base64");
			const notification = JSON.parse(dataBuffer.toString());

			console.log(
				"Received Play Store notification:",
				JSON.stringify(notification),
			);

			const subscriptionNotification = notification.subscriptionNotification;
			if (!subscriptionNotification) {
				console.log("Not a subscription notification, ignoring");
				res.status(200).send("OK");
				return;
			}

			const { purchaseToken, notificationType } = subscriptionNotification;

			// Notification types:
			// 1 = SUBSCRIPTION_RECOVERED
			// 2 = SUBSCRIPTION_RENEWED
			// 3 = SUBSCRIPTION_CANCELED
			// 4 = SUBSCRIPTION_PURCHASED
			// 5 = SUBSCRIPTION_ON_HOLD
			// 6 = SUBSCRIPTION_IN_GRACE_PERIOD
			// 7 = SUBSCRIPTION_RESTARTED
			// 12 = SUBSCRIPTION_REVOKED
			// 13 = SUBSCRIPTION_EXPIRED

			console.log(
				`Processing notification type ${notificationType} for token ${purchaseToken}`,
			);

			// Find the user associated with this subscription first
			const subDoc = await db
				.collection("subscriptions")
				.doc(purchaseToken)
				.get();

			if (!subDoc.exists) {
				console.log(
					"Subscription not found in database, might be a new purchase",
				);
				res.status(200).send("OK");
				return;
			}

			const subData = subDoc.data();
			if (!subData) {
				console.log("Subscription data is empty");
				res.status(200).send("OK");
				return;
			}
			const userId = subData.userId;

			// Try to get subscription details from Google Play
			// If this fails (e.g., permissions issue), we can still handle
			// terminal states based on the notification type alone
			let subscriptionState: string | null = null;
			let expiresAt: Timestamp | null = null;

			try {
				const playApi = await getPlayDeveloperApi(
					googlePlayCredentials.value(),
				);
				const response = await playApi.purchases.subscriptionsv2.get({
					packageName: ANDROID_PACKAGE_NAME,
					token: purchaseToken,
				});

				const subscription = response.data;
				if (subscription) {
					subscriptionState = subscription.subscriptionState || null;

					// Extract expiry time from line items
					const lineItems = subscription.lineItems as
						| Array<{ expiryTime?: string }>
						| undefined;
					if (lineItems) {
						for (const lineItem of lineItems) {
							if (lineItem.expiryTime) {
								expiresAt = Timestamp.fromDate(new Date(lineItem.expiryTime));
								break;
							}
						}
					}
				}
			} catch (apiError) {
				console.warn(
					`Failed to get subscription details from Google Play API: ${apiError}`,
				);
				// Continue processing based on notification type alone
				// Map notification types to subscription states
				const notificationToState: Record<number, string> = {
					1: "SUBSCRIPTION_STATE_ACTIVE", // RECOVERED
					2: "SUBSCRIPTION_STATE_ACTIVE", // RENEWED
					3: "SUBSCRIPTION_STATE_CANCELED", // CANCELED
					5: "SUBSCRIPTION_STATE_ON_HOLD", // ON_HOLD
					6: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", // GRACE_PERIOD
					7: "SUBSCRIPTION_STATE_ACTIVE", // RESTARTED
					12: "SUBSCRIPTION_STATE_CANCELED", // REVOKED
					13: "SUBSCRIPTION_STATE_EXPIRED", // EXPIRED
				};
				subscriptionState = notificationToState[notificationType] || null;
			}

			// Update subscription record (use set with merge to handle missing fields)
			const subscriptionUpdate: Record<string, unknown> = {
				notificationType,
				lastNotificationAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			};
			if (subscriptionState) {
				subscriptionUpdate.subscriptionState = subscriptionState;
			}
			if (expiresAt) {
				subscriptionUpdate.expiresAt = expiresAt;
			}
			await db
				.collection("subscriptions")
				.doc(purchaseToken)
				.set(subscriptionUpdate, { merge: true });

			// Update user's subscription status
			const userSubRef = db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status");

			const isActive =
				subscriptionState === "SUBSCRIPTION_STATE_ACTIVE" ||
				subscriptionState === "SUBSCRIPTION_STATE_IN_GRACE_PERIOD";

			// Terminal states - subscription is fully ended
			const isTerminal =
				subscriptionState === "SUBSCRIPTION_STATE_EXPIRED" ||
				notificationType === 12 || // REVOKED
				notificationType === 13; // EXPIRED

			if (isActive) {
				await userSubRef.set(
					{
						expiresAt,
						willAutoRenew: subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
						subscriptionState,
						updatedAt: FieldValue.serverTimestamp(),
					},
					{ merge: true },
				);

				// Update custom claims for server-side enforcement
				if (expiresAt) {
					await setSubscriptionClaims(userId, "pro", expiresAt.toDate());
				}
			} else if (isTerminal) {
				// Terminal state - remove subscription to revert user to free plan
				console.log(`Terminal state for user ${userId}, removing subscription`);
				await userSubRef.delete();

				// Clear custom claims - user is now on free plan
				await setSubscriptionClaims(userId, "free", null);

				// Send notification email
				await sendSubscriptionNotificationEmail(
					userId,
					notificationType,
					expiresAt?.toDate() || null,
				);
			} else {
				// Non-terminal but not active (e.g., canceled but not yet expired, on hold)
				const shouldNotify = [3, 5, 6].includes(notificationType);

				if (shouldNotify) {
					await sendSubscriptionNotificationEmail(
						userId,
						notificationType,
						expiresAt?.toDate() || null,
					);
				}

				// Update status
				await userSubRef.set(
					{
						willAutoRenew: false,
						subscriptionState,
						updatedAt: FieldValue.serverTimestamp(),
					},
					{ merge: true },
				);
			}

			console.log(
				`Processed notification for user ${userId}: type=${notificationType}, state=${subscriptionState}`,
			);
			res.status(200).send("OK");
		} catch (error) {
			console.error("Error processing Play Store webhook:", error);
			res.status(500).send("Internal error");
		}
	},
);

/**
 * Send subscription notification email to user
 */
async function sendSubscriptionNotificationEmail(
	userId: string,
	notificationType: number,
	expiresAt: Date | null,
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

		let subject: string;
		let heading: string;
		let message: string;
		let actionText: string | null = null;
		let actionUrl: string | null = null;
		let extraContent: string = "";

		switch (notificationType) {
			case 3: // SUBSCRIPTION_CANCELED
				subject = "Your Better Keep Notes Pro subscription has been cancelled";
				heading = "Subscription Cancelled";
				message = expiresAt
					? `Your <strong>Better Keep Notes Pro</strong> subscription has been cancelled. You will continue to have access to Pro features until <strong>${expiresAt.toLocaleDateString()}</strong>.`
					: "Your <strong>Better Keep Notes Pro</strong> subscription has been cancelled.";
				extraContent = `
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            We would genuinely like to understand what led to this decision. Was there something missing, or something we could have done better?
          </p>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            If you have a moment, please share your feedback with us at <a href="mailto:feedback@betterkeep.app" style="color: #6366f1;">feedback@betterkeep.app</a>. It helps us improve <strong>Better Keep Notes</strong> for everyone.
          </p>
          <p style="color: #555; font-size: 15px; line-height: 1.6;">
            If you ever decide to come back, we'll be happy to have you.
          </p>
        `;
				actionText = "Resubscribe";
				actionUrl = "https://betterkeep.app/subscribe";
				break;

			case 5: // SUBSCRIPTION_ON_HOLD
				subject =
					"Action required: Your Better Keep Notes Pro subscription is on hold";
				heading = "Payment Issue";
				message =
					"We couldn't process your payment for <strong>Better Keep Notes Pro</strong>. Please update your payment method to continue your subscription.";
				actionText = "Update Payment";
				actionUrl = "https://play.google.com/store/account/subscriptions";
				break;

			case 6: // SUBSCRIPTION_IN_GRACE_PERIOD
				subject = "Payment issue with your Better Keep Notes Pro subscription";
				heading = "Grace Period Active";
				message =
					"We're having trouble processing your payment for <strong>Better Keep Notes Pro</strong>. You have a few days to update your payment method before losing access to Pro features.";
				actionText = "Update Payment";
				actionUrl = "https://play.google.com/store/account/subscriptions";
				break;

			case 12: // SUBSCRIPTION_REVOKED
				subject = "Your Better Keep Notes Pro subscription has been revoked";
				heading = "Subscription Revoked";
				message =
					"Your <strong>Better Keep Notes Pro</strong> subscription has been revoked. If you believe this is an error, please contact support.";
				actionText = "Contact Support";
				actionUrl = "mailto:support@betterkeep.app";
				break;

			case 13: // SUBSCRIPTION_EXPIRED
				subject = "Your Better Keep Notes Pro subscription has expired";
				heading = "Subscription Expired";
				message =
					"Your <strong>Better Keep Notes Pro</strong> subscription has expired. Resubscribe to regain access to unlimited locked notes, cloud sync, and more.";
				actionText = "Resubscribe";
				actionUrl = "https://betterkeep.app/subscribe";
				break;

			default:
				return; // Don't send email for other types
		}

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
          <h1 style="color: #333; font-size: 22px; margin-bottom: 20px;">${heading}</h1>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            ${message}
          </p>
          ${extraContent}
          ${
						actionText && actionUrl
							? `
          <div style="margin: 24px 0;">
            <a href="${actionUrl}" style="display: inline-block; background: #6366f1; color: white; padding: 12px 24px; border-radius: 8px; text-decoration: none; font-weight: 600; font-size: 15px;">
              ${actionText}
            </a>
          </div>
          `
							: ""
					}
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 13px;">
            If you have questions, contact us at <a href="mailto:support@betterkeep.app" style="color: #6366f1;">support@betterkeep.app</a>
          </p>
          <p style="color: #999; font-size: 13px; margin-top: 8px;">
            <strong>Better Keep Notes</strong> by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `;

		// For cancellation emails, add reply-to for feedback
		const replyTo =
			notificationType === 3 ? "feedback@betterkeep.app" : undefined;

		await sendEmail(transporter, {
			from: `"${senderName}" <${senderEmail}>`,
			replyTo: replyTo,
			to: email,
			subject,
			html: htmlContent,
			text: `${heading}\n\n${message}${
				extraContent
					? "\n\nWe'd love to hear your feedback! Reply to this email or write to feedback@betterkeep.app"
					: ""
			}${actionUrl ? `\n\n${actionText}: ${actionUrl}` : ""}`,
		});

		console.log(`Sent subscription notification email to ${email}`);
	} catch (error) {
		console.error(
			`Failed to send subscription email to user ${userId}:`,
			error,
		);
	}
}
