import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { db } from "../config";
import { setSubscriptionClaims } from "../utils";

type JwtPayload = Record<string, unknown>;

function decodeBase64Url(value: string): string {
	const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
	const padding = normalized.length % 4;
	const padded =
		padding === 0 ? normalized : normalized + "=".repeat(4 - padding);
	return Buffer.from(padded, "base64").toString("utf8");
}

function parseJwtPayload(jwt: string): JwtPayload {
	const parts = jwt.split(".");
	if (parts.length < 2) {
		throw new Error("Invalid JWT format");
	}
	const payloadJson = decodeBase64Url(parts[1]);
	return JSON.parse(payloadJson) as JwtPayload;
}

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

export default onRequest(async (req, res) => {
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

		// Note: payload is decoded but signature is not cryptographically verified yet.
		const payload = parseJwtPayload(signedPayload);
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

		const transactionPayload = parseJwtPayload(signedTransactionInfo);
		const renewalPayload = signedRenewalInfo
			? parseJwtPayload(signedRenewalInfo)
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

		console.log("=== App Store Webhook Processed Successfully ===");
		res.status(200).send("OK");
	} catch (error) {
		console.error("Error processing App Store webhook:", error);
		res.status(500).send("Internal error");
	}
});
