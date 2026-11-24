import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { verifyAppleJws } from "../appleJwsVerify";
import {
	appStoreEffectiveExpiryMillis,
	appStoreWillAutoRenew,
	resolveAppStoreNotification,
} from "../appStoreSubscription";
import {
	appStoreBillingActivityType,
	writeBillingActivity,
} from "../billingActivity";
import { auth, db, emailPassword } from "../config";
import {
	formatEmailDate,
	generateTransactionalEmail,
} from "../email_templates";
import { enqueueRevenueEventInTransaction } from "../revenueOutbox";
import { normalizedSubscriptionFields } from "../subscriptionEntitlement";
import { recordSubscriptionIssue } from "../subscriptionIssues";
import { appleSubscriptionProduct } from "../subscriptionProducts";
import { reconcileUserEntitlement } from "../subscriptionReconciler";
import { sendEmail } from "../utils";

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
	console.log("Request metadata:", {
		contentType: req.headers["content-type"] ?? null,
		userAgent: req.headers["user-agent"] ?? null,
	});
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
		const notificationSignedDateMs = getNumber(payload, "signedDate");

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
		const purchaseDateMs = getNumber(transactionPayload, "purchaseDate");
		const price = getNumber(transactionPayload, "price");
		const currency = getString(transactionPayload, "currency");
		const environment = getString(transactionPayload, "environment");

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

		const product = appleSubscriptionProduct(productId ?? "");
		if (!product) {
			await recordSubscriptionIssue({
				type: "app_store_unknown_product",
				source: "app_store",
				providerKey: originalTransactionId,
				details: { productId },
			});
			await dedupeRef.set({
				notificationType,
				subtype,
				productId,
				status: "ignored_unknown_product",
				processedAt: FieldValue.serverTimestamp(),
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

		const decision = resolveAppStoreNotification(notificationType, subtype);
		console.log("Notification decision:", decision.kind);
		if (decision.kind === "unknown") {
			await recordSubscriptionIssue({
				type: "app_store_unhandled_notification",
				source: "app_store",
				providerKey: `${originalTransactionId}:${notificationType}:${subtype ?? "none"}`,
				userId,
				details: { notificationType, subtype },
			});
		}

		const previousExpiresAt =
			subData?.expiresAt instanceof Timestamp
				? subData.expiresAt.toMillis()
				: null;
		const effectiveExpiryMillis = appStoreEffectiveExpiryMillis({
			decision,
			existingExpiryMillis: previousExpiresAt,
			notificationSignedDateMillis: notificationSignedDateMs,
			now: Date.now(),
			providerExpiryMillis: expiresDateMs,
			revocationDateMillis: revocationDateMs,
		});
		const expiresAt =
			effectiveExpiryMillis === null
				? null
				: Timestamp.fromMillis(effectiveExpiryMillis);
		const renewalStatus = getNumber(renewalPayload || {}, "autoRenewStatus");
		const willAutoRenew = appStoreWillAutoRenew(decision, renewalStatus);
		const revenueKind =
			notificationType === "REFUND"
				? "refund"
				: notificationType === "SUBSCRIBED" || notificationType === "DID_RENEW"
					? "charge"
					: null;
		const revenueOccurredAtMs =
			revenueKind === "refund"
				? (revocationDateMs ?? notificationSignedDateMs)
				: purchaseDateMs;

		const revenueEvent =
			revenueKind &&
			transactionId &&
			price !== null &&
			Number.isSafeInteger(price) &&
			price >= 0 &&
			Number.isSafeInteger(price * 1000) &&
			currency &&
			revenueOccurredAtMs !== null
				? ({
						provider: "app_store",
						providerTransactionId:
							revenueKind === "refund"
								? `${transactionId}:refund`
								: transactionId,
						userId,
						amountMicros: price * 1000,
						currency,
						kind: revenueKind,
						environment:
							environment === "Production" ? "production" : "sandbox",
						occurredAt: new Date(revenueOccurredAtMs),
						metadata: { originalTransactionId, productId },
					} as const)
				: null;

		const stateUpdate =
			decision.kind === "state_change"
				? {
						...normalizedSubscriptionFields(
							{
								environment:
									environment === "Production"
										? "production"
										: environment === "Sandbox"
											? "test"
											: "unknown",
								expiresAt,
								plan: product.plan,
								source: "app_store",
								subscriptionState: decision.subscriptionState,
								willAutoRenew,
							},
							Date.now(),
						),
						expiresAt,
						willAutoRenew,
					}
				: {};

		await db.runTransaction(async (transaction) => {
			let revenueEventId: string | null = null;
			if (revenueEvent) {
				revenueEventId = await enqueueRevenueEventInTransaction(
					transaction,
					revenueEvent,
				);
			}
			transaction.set(
				subscriptionRef,
				{
					...stateUpdate,
					productId,
					purchaseToken: originalTransactionId,
					originalTransactionId,
					externalAccountVerified: true,
					lastVerifiedAt: FieldValue.serverTimestamp(),
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
			writeBillingActivity(transaction, {
				provider: "app_store",
				eventKey: notificationUUID,
				eventType: appStoreBillingActivityType(notificationType, subtype),
				occurredAt: new Date(
					notificationSignedDateMs ?? purchaseDateMs ?? Date.now(),
				),
				userId,
				productId,
				environment:
					environment === "Production"
						? "production"
						: environment === "Sandbox"
							? "test"
							: "unknown",
				subscriptionState:
					decision.kind === "state_change" ? decision.subscriptionState : null,
				amountMicros: revenueEvent?.amountMicros,
				currency: revenueEvent?.currency,
				revenueKind: revenueEvent?.kind,
				revenueEventId,
			});
		});

		if (decision.kind === "state_change") {
			await reconcileUserEntitlement(userId);
		}

		await dedupeRef.set({
			notificationType,
			subtype,
			originalTransactionId,
			transactionId,
			processedAt: FieldValue.serverTimestamp(),
			status:
				decision.kind === "state_change"
					? "processed"
					: decision.kind === "metadata_only"
						? "processed_metadata_only"
						: "ignored_unknown_notification",
		});

		// Send notification email for relevant events (don't block response).
		// Guard against cancel→expiry double-email: if a cancellation email was
		// already sent for this subscription, skip sending the expiry email.
		if (userId && notificationType && decision.kind === "state_change") {
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
		let feedbackRequested = false;
		let replyTo: string | undefined;

		if (
			notificationType === "DID_CHANGE_RENEWAL_STATUS" &&
			subtype === "AUTO_RENEW_DISABLED"
		) {
			subject = "Your Better Keep Notes Pro subscription has been cancelled";
			heading = "Subscription cancelled";
			message = expiresAt
				? `Your Better Keep Notes Pro subscription has been cancelled. You will continue to have access to Pro features until ${formatEmailDate(expiresAt)}.`
				: "Your Better Keep Notes Pro subscription has been cancelled.";
			feedbackRequested = true;
			actionText = "Resubscribe";
			actionUrl = "https://betterkeep.app/subscribe";
			replyTo = "feedback@betterkeep.app";
		} else if (notificationType === "EXPIRED") {
			subject = "Your Better Keep Notes Pro subscription has expired";
			heading = "Subscription expired";
			message =
				"Your Better Keep Notes Pro subscription has expired. Resubscribe to regain access to unlimited locked notes, cloud sync, and more.";
			actionText = "Resubscribe";
			actionUrl = "https://betterkeep.app/subscribe";
		} else if (notificationType === "REVOKE") {
			subject = "Your Better Keep Notes Pro subscription has been revoked";
			heading = "Subscription revoked";
			message =
				"Your Better Keep Notes Pro subscription has been revoked. If you believe this is an error, please contact support.";
			actionText = "Contact Support";
			actionUrl = "mailto:support@betterkeep.app";
		} else if (
			notificationType === "DID_FAIL_TO_RENEW" &&
			subtype === "GRACE_PERIOD"
		) {
			subject = "Payment issue with your Better Keep Notes Pro subscription";
			heading = "Update your payment method";
			message =
				"We're having trouble processing your payment for Better Keep Notes Pro. You have a few days to update your payment method before losing access to Pro features.";
			actionText = "Update Payment";
			actionUrl = "https://apps.apple.com/account/subscriptions";
		} else {
			// Don't send email for other notification types
			return;
		}

		await sendEmail({
			from: `"${senderName}" <${senderEmail}>`,
			replyTo,
			to: email,
			subject,
			...generateTransactionalEmail({
				title: heading,
				category: "Subscription",
				paragraphs: [message],
				notice: feedbackRequested
					? {
							title: "What could we do better?",
							text: "Reply to this email or write to feedback@betterkeep.app.",
						}
					: undefined,
				action:
					actionText && actionUrl
						? { label: actionText, url: actionUrl }
						: undefined,
			}),
		});

		console.log("Sent App Store notification email");
	} catch (error) {
		console.error(
			`Failed to send App Store notification email to user ${userId}:`,
			error,
		);
	}
}
