import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { verifyAppleJws } from "../appleJwsVerify";
import { auth, db, emailPassword } from "../config";
import { sendEmail, setSubscriptionClaims } from "../utils";

type JwtPayload = Record<string, unknown>;

function getString(payload: JwtPayload, key: string): string | null {
	const value = payload[key];
	return typeof value === "string" && value.length > 0 ? value : null;
}

function getNumber(payload: JwtPayload, key: string): number | null {
	const value = payload[key];
	if (typeof value === "number") return value;
	if (typeof value === "string") {
		const parsed = Number(value);
		return Number.isFinite(parsed) ? parsed : null;
	}
	return null;
}

function mapNotificationToState(
	notificationType: string,
	subtype: string | null,
): { state: string; isActive: boolean; isTerminal: boolean } {
	if (notificationType === "SUBSCRIBED" || notificationType === "DID_RENEW") {
		return {
			state: "SUBSCRIPTION_STATE_ACTIVE",
			isActive: true,
			isTerminal: false,
		};
	}

	if (notificationType === "DID_FAIL_TO_RENEW" && subtype === "GRACE_PERIOD") {
		return {
			state: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
			isActive: true,
			isTerminal: false,
		};
	}

	if (notificationType === "EXPIRED" || notificationType === "REVOKE") {
		return {
			state: "SUBSCRIPTION_STATE_EXPIRED",
			isActive: false,
			isTerminal: true,
		};
	}

	if (notificationType === "REFUND") {
		return {
			state: "SUBSCRIPTION_STATE_CANCELED",
			isActive: false,
			isTerminal: true,
		};
	}

	if (notificationType === "DID_CHANGE_RENEWAL_STATUS") {
		if (subtype === "AUTO_RENEW_ENABLED") {
			return {
				state: "SUBSCRIPTION_STATE_ACTIVE",
				isActive: true,
				isTerminal: false,
			};
		}
		return {
			state: "SUBSCRIPTION_STATE_CANCELED",
			isActive: false,
			isTerminal: false,
		};
	}

	return {
		state: "SUBSCRIPTION_STATE_PENDING",
		isActive: false,
		isTerminal: false,
	};
}

export default onRequest({ secrets: [emailPassword] }, async (req, res) => {
	// GET request for testing if the webhook URL is reachable
	if (req.method === "GET") {
		console.log("App Store webhook GET test hit at", new Date().toISOString());
		res.status(200).json({
			status: "ok",
			message: "App Store webhook endpoint is reachable",
			timestamp: new Date().toISOString(),
		});
		return;
	}

	if (req.method !== "POST") {
		res.status(405).send("Method not allowed");
		return;
	}

	console.log("=== App Store Webhook Received ===");
	console.log("Timestamp:", new Date().toISOString());
	console.log("Headers:", JSON.stringify(req.headers, null, 2));
	console.log("Raw body type:", typeof req.body);
	console.log("Raw body keys:", req.body ? Object.keys(req.body) : "null");

	// Optional hardening: if APP_STORE_WEBHOOK_TOKEN is configured, require Bearer auth.
	const expectedToken = process.env.APP_STORE_WEBHOOK_TOKEN;
	if (expectedToken) {
		const authHeader = req.headers.authorization;
		if (authHeader !== `Bearer ${expectedToken}`) {
			console.error(
				"Webhook auth failed - expected token but got:",
				authHeader,
			);
			res.status(403).send("Forbidden");
			return;
		}
	}

	try {
		const signedPayload = req.body?.signedPayload;
		if (typeof signedPayload !== "string") {
			console.error(
				"Invalid payload - signedPayload is not a string:",
				typeof signedPayload,
			);
			res.status(400).send("Invalid payload");
			return;
		}

		const payload = await verifyAppleJws(signedPayload);
		const notificationType = getString(payload, "notificationType");
		const subtype = getString(payload, "subtype");
		const notificationUUID = getString(payload, "notificationUUID");

		console.log("Notification type:", notificationType);
		console.log("Notification subtype:", subtype);
		console.log("Notification UUID:", notificationUUID);

		if (!notificationType || !notificationUUID) {
			console.error(
				"Missing notification fields - type:",
				notificationType,
				"uuid:",
				notificationUUID,
			);
			res.status(400).send("Missing notification fields");
			return;
		}

		const dedupeRef = db
			.collection("appStoreWebhookEvents")
			.doc(notificationUUID);
		const existingEvent = await dedupeRef.get();
		if (existingEvent.exists) {
			console.log("Duplicate event, skipping:", notificationUUID);
			res.status(200).send("OK");
			return;
		}

		const data = payload.data as Record<string, unknown> | undefined;
		const signedTransactionInfo =
			typeof data?.signedTransactionInfo === "string"
				? data.signedTransactionInfo
				: null;
		const signedRenewalInfo =
			typeof data?.signedRenewalInfo === "string"
				? data.signedRenewalInfo
				: null;

		if (!signedTransactionInfo) {
			console.log(
				"No signedTransactionInfo, ignoring event:",
				notificationType,
			);
			await dedupeRef.set({
				notificationType,
				subtype,
				processedAt: FieldValue.serverTimestamp(),
				status: "ignored_no_transaction",
			});
			res.status(200).send("OK");
			return;
		}

		const transactionPayload = await verifyAppleJws(signedTransactionInfo);
		const renewalPayload = signedRenewalInfo
			? await verifyAppleJws(signedRenewalInfo)
			: null;

		const originalTransactionId = getString(
			transactionPayload,
			"originalTransactionId",
		);
		const transactionId = getString(transactionPayload, "transactionId");
		const productId = getString(transactionPayload, "productId");
		const expiresDateMs = getNumber(transactionPayload, "expiresDate");
		const revocationDateMs = getNumber(transactionPayload, "revocationDate");

		console.log("Transaction details:", {
			originalTransactionId,
			transactionId,
			productId,
			expiresDateMs,
			expiresDate: expiresDateMs ? new Date(expiresDateMs).toISOString() : null,
			revocationDateMs,
		});

		if (!originalTransactionId || !productId) {
			console.error(
				"Missing transaction fields - originalTransactionId:",
				originalTransactionId,
				"productId:",
				productId,
			);
			await dedupeRef.set({
				notificationType,
				subtype,
				processedAt: FieldValue.serverTimestamp(),
				status: "ignored_missing_transaction_fields",
			});
			res.status(200).send("OK");
			return;
		}

		const subscriptionId = `ios_${originalTransactionId}`;
		const subscriptionRef = db.collection("subscriptions").doc(subscriptionId);
		const subSnap = await subscriptionRef.get();

		if (!subSnap.exists) {
			console.warn("Subscription not found in Firestore:", subscriptionId);
			await dedupeRef.set({
				notificationType,
				subtype,
				originalTransactionId,
				transactionId,
				processedAt: FieldValue.serverTimestamp(),
				status: "ignored_subscription_not_found",
			});
			res.status(200).send("OK");
			return;
		}

		const subData = subSnap.data();
		const userId = subData?.userId as string | undefined;
		console.log(
			"Found subscription for user:",
			userId,
			"subscriptionId:",
			subscriptionId,
		);
		if (!userId) {
			await dedupeRef.set({
				notificationType,
				subtype,
				originalTransactionId,
				processedAt: FieldValue.serverTimestamp(),
				status: "ignored_missing_user",
			});
			res.status(200).send("OK");
			return;
		}

		const mapped = mapNotificationToState(notificationType, subtype);
		console.log("Mapped state:", mapped);
		const expiresAt =
			typeof expiresDateMs === "number"
				? Timestamp.fromMillis(expiresDateMs)
				: subData?.expiresAt || null;

		const renewalStatus = getNumber(renewalPayload || {}, "autoRenewStatus");
		const willAutoRenew =
			renewalStatus === 1
				? true
				: mapped.isActive && mapped.state === "SUBSCRIPTION_STATE_ACTIVE";

		await subscriptionRef.set(
			{
				productId,
				purchaseToken: originalTransactionId,
				originalTransactionId,
				source: "app_store",
				subscriptionState: mapped.state,
				willAutoRenew,
				expiresAt,
				notificationType,
				notificationSubtype: subtype,
				lastTransactionId: transactionId,
				revocationDate: revocationDateMs
					? Timestamp.fromMillis(revocationDateMs)
					: null,
				lastNotificationAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);

		const userSubRef = db
			.collection("users")
			.doc(userId)
			.collection("subscription")
			.doc("status");

		if (mapped.isActive && expiresAt) {
			console.log(
				"Updating user subscription to ACTIVE - userId:",
				userId,
				"plan: pro",
			);
			await userSubRef.set(
				{
					plan: "pro",
					billingPeriod:
						productId.includes("year") || productId.includes("annual")
							? "yearly"
							: "monthly",
					expiresAt,
					willAutoRenew,
					subscriptionState: mapped.state,
					purchaseToken: originalTransactionId,
					source: "app_store",
					updatedAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);

			await setSubscriptionClaims(userId, "pro", expiresAt.toDate());
		} else if (mapped.isTerminal) {
			console.log("Terminal state - removing subscription for userId:", userId);
			await userSubRef.delete();
			await setSubscriptionClaims(userId, "free", null);
		} else {
			console.log(
				"Non-terminal inactive state - updating status for userId:",
				userId,
			);
			await userSubRef.set(
				{
					willAutoRenew,
					subscriptionState: mapped.state,
					updatedAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);
		}

		await dedupeRef.set({
			notificationType,
			subtype,
			originalTransactionId,
			transactionId,
			processedAt: FieldValue.serverTimestamp(),
			status: "processed",
		});

		// Send notification email for relevant events (don't block response).
		// Guard against cancel→expiry double-email: if a cancellation email was
		// already sent for this subscription, skip sending the expiry email.
		if (userId && notificationType) {
			const expiresDate = expiresDateMs ? new Date(expiresDateMs) : null;
			const subscriptionId = `ios_${originalTransactionId}`;

			const isCancelEmail =
				notificationType === "DID_CHANGE_RENEWAL_STATUS" &&
				subtype === "AUTO_RENEW_DISABLED";
			const isExpiryEmail = notificationType === "EXPIRED";

			if (isCancelEmail) {
				// Set the flag only after the email is successfully dispatched so a
				// transient mailer failure doesn't permanently suppress it and leave
				// the user with zero emails when EXPIRED arrives later.
				sendAppStoreNotificationEmail(
					userId,
					notificationType,
					subtype,
					expiresDate,
				)
					.then(() =>
						db
							.collection("subscriptions")
							.doc(subscriptionId)
							.set(
								{ cancelEmailSentAt: FieldValue.serverTimestamp() },
								{ merge: true },
							),
					)
					.catch((err) =>
						console.error("Failed to send App Store notification email:", err),
					);
			} else if (isExpiryEmail) {
				// Only send expiry email if no cancellation email was sent earlier
				const subSnap2 = await db
					.collection("subscriptions")
					.doc(subscriptionId)
					.get();
				const alreadySentCancelEmail =
					subSnap2.exists && subSnap2.data()?.cancelEmailSentAt != null;
				if (!alreadySentCancelEmail) {
					sendAppStoreNotificationEmail(
						userId,
						notificationType,
						subtype,
						expiresDate,
					).catch((err) =>
						console.error("Failed to send App Store notification email:", err),
					);
				} else {
					console.log(
						`Skipping EXPIRED email for ${subscriptionId} — cancellation email already sent`,
					);
				}
			} else {
				sendAppStoreNotificationEmail(
					userId,
					notificationType,
					subtype,
					expiresDate,
				).catch((err) =>
					console.error("Failed to send App Store notification email:", err),
				);
			}
		}

		console.log("=== App Store Webhook Processed Successfully ===");
		res.status(200).send("OK");
	} catch (error) {
		const errorMessage = error instanceof Error ? error.message : String(error);
		if (
			errorMessage.includes("certificate") ||
			errorMessage.includes("x5c") ||
			errorMessage.includes("signature") ||
			errorMessage.includes("JWS")
		) {
			console.error("JWS signature verification failed:", errorMessage);
			res.status(403).send("Signature verification failed");
			return;
		}
		console.error("Error processing App Store webhook:", error);
		res.status(500).send("Internal error");
	}
});

/**
 * Send subscription notification email for App Store events
 */
async function sendAppStoreNotificationEmail(
	userId: string,
	notificationType: string,
	subtype: string | null,
	expiresAt: Date | null,
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

		let subject: string;
		let heading: string;
		let message: string;
		let actionText: string | null = null;
		let actionUrl: string | null = null;
		let extraContent = "";
		let replyTo: string | undefined;

		if (
			notificationType === "DID_CHANGE_RENEWAL_STATUS" &&
			subtype === "AUTO_RENEW_DISABLED"
		) {
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
			replyTo = "feedback@betterkeep.app";
		} else if (notificationType === "EXPIRED") {
			subject = "Your Better Keep Notes Pro subscription has expired";
			heading = "Subscription Expired";
			message =
				"Your <strong>Better Keep Notes Pro</strong> subscription has expired. Resubscribe to regain access to unlimited locked notes, cloud sync, and more.";
			actionText = "Resubscribe";
			actionUrl = "https://betterkeep.app/subscribe";
		} else if (notificationType === "REVOKE") {
			subject = "Your Better Keep Notes Pro subscription has been revoked";
			heading = "Subscription Revoked";
			message =
				"Your <strong>Better Keep Notes Pro</strong> subscription has been revoked. If you believe this is an error, please contact support.";
			actionText = "Contact Support";
			actionUrl = "mailto:support@betterkeep.app";
		} else if (
			notificationType === "DID_FAIL_TO_RENEW" &&
			subtype === "GRACE_PERIOD"
		) {
			subject = "Payment issue with your Better Keep Notes Pro subscription";
			heading = "Grace Period Active";
			message =
				"We're having trouble processing your payment for <strong>Better Keep Notes Pro</strong>. You have a few days to update your payment method before losing access to Pro features.";
			actionText = "Update Payment";
			actionUrl = "https://apps.apple.com/account/subscriptions";
		} else {
			// Don't send email for other notification types
			return;
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

		await sendEmail({
			from: `"${senderName}" <${senderEmail}>`,
			replyTo,
			to: email,
			subject,
			html: htmlContent,
			text: `${heading}\n\n${message.replace(/<[^>]*>/g, "")}${
				extraContent
					? "\n\nWe'd love to hear your feedback! Reply to this email or write to feedback@betterkeep.app"
					: ""
			}${actionUrl ? `\n\n${actionText}: ${actionUrl}` : ""}`,
		});

		console.log(`Sent App Store notification email to ${email}`);
	} catch (error) {
		console.error(
			`Failed to send App Store notification email to user ${userId}:`,
			error,
		);
	}
}
