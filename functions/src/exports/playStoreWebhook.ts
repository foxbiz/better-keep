import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { error as logError, info as logInfo } from "firebase-functions/logger";
import { onMessagePublished } from "firebase-functions/v2/pubsub";
import { PLAY_STORE_EVENT_COLLECTION } from "../adminConfig";
import { ANDROID_PACKAGE_NAME, db, googlePlayCredentials } from "../config";
import { syncGooglePlayOrderById } from "../googlePlayRevenue";
import { refreshGooglePlaySubscription } from "../googlePlayService";
import { reconcileUserEntitlement } from "../subscriptionReconciler";

interface PlayNotification {
	packageName?: string;
	subscriptionNotification?: {
		notificationType?: number;
		purchaseToken?: string;
	};
	testNotification?: { version?: string };
	voidedPurchaseNotification?: {
		orderId?: string;
		purchaseToken?: string;
	};
}

const EVENT_LEASE_MILLIS = 5 * 60 * 1000;

export type PlayEventClaimOutcome = "claimed" | "succeeded" | "busy";

export class PlayEventBusyError extends Error {
	readonly code = "play-event-busy";

	constructor() {
		super("Google Play notification processing is still in progress");
		this.name = "PlayEventBusyError";
	}
}

export function playEventClaimOutcome(
	data: Record<string, unknown>,
	nowMillis: number,
): PlayEventClaimOutcome {
	if (data.status === "succeeded") return "succeeded";
	if (
		data.status === "processing" &&
		data.leaseUntil instanceof Timestamp &&
		data.leaseUntil.toMillis() > nowMillis
	) {
		return "busy";
	}
	return "claimed";
}

export async function executeClaimedPlayEvent({
	claim,
	complete,
	fail,
	process,
}: {
	claim: () => Promise<PlayEventClaimOutcome>;
	complete: () => Promise<void>;
	fail: (error: unknown) => Promise<void>;
	process: () => Promise<void>;
}): Promise<"duplicate" | "processed"> {
	const outcome = await claim();
	if (outcome === "succeeded") return "duplicate";
	if (outcome === "busy") throw new PlayEventBusyError();
	try {
		await process();
		await complete();
		return "processed";
	} catch (error) {
		await fail(error);
		throw error;
	}
}

export function safePlayEventLogData(notification: PlayNotification) {
	return {
		packageName: notification.packageName ?? null,
		notificationType:
			notification.subscriptionNotification?.notificationType ?? null,
		hasSubscriptionNotification: Boolean(notification.subscriptionNotification),
		hasVoidedPurchaseNotification: Boolean(
			notification.voidedPurchaseNotification,
		),
		isTestNotification: Boolean(notification.testNotification),
	};
}

async function claimEvent(messageId: string): Promise<PlayEventClaimOutcome> {
	const ref = db.collection(PLAY_STORE_EVENT_COLLECTION).doc(messageId);
	const now = Timestamp.now();
	return db.runTransaction(async (transaction) => {
		const snapshot = await transaction.get(ref);
		const data = snapshot.data() ?? {};
		const outcome = playEventClaimOutcome(data, now.toMillis());
		if (outcome !== "claimed") return outcome;
		transaction.set(
			ref,
			{
				status: "processing",
				attempts: Math.max(0, Number(data.attempts) || 0) + 1,
				leaseUntil: Timestamp.fromMillis(now.toMillis() + EVENT_LEASE_MILLIS),
				createdAt: data.createdAt ?? now,
				updatedAt: now,
			},
			{ merge: true },
		);
		return "claimed";
	});
}

async function completeEvent(messageId: string): Promise<void> {
	await db.collection(PLAY_STORE_EVENT_COLLECTION).doc(messageId).set(
		{
			status: "succeeded",
			leaseUntil: null,
			processedAt: FieldValue.serverTimestamp(),
			updatedAt: FieldValue.serverTimestamp(),
		},
		{ merge: true },
	);
}

async function failEvent(messageId: string, error: unknown): Promise<void> {
	const code =
		typeof (error as { code?: unknown }).code === "string"
			? (error as { code: string }).code.slice(0, 120)
			: error instanceof Error
				? error.name.slice(0, 120)
				: "unknown";
	await db.collection(PLAY_STORE_EVENT_COLLECTION).doc(messageId).set(
		{
			status: "failed",
			lastErrorCode: code,
			lastFailedAt: FieldValue.serverTimestamp(),
			leaseUntil: null,
			updatedAt: FieldValue.serverTimestamp(),
		},
		{ merge: true },
	);
}

export async function processPlayNotification(
	notification: PlayNotification,
): Promise<void> {
	if (notification.testNotification) return;
	if (notification.packageName !== ANDROID_PACKAGE_NAME) {
		throw new Error("Google Play notification package name mismatch");
	}

	const subscription = notification.subscriptionNotification;
	if (subscription) {
		if (!subscription.purchaseToken) {
			throw new Error("Google Play subscription notification has no token");
		}
		await refreshGooglePlaySubscription({
			purchaseToken: subscription.purchaseToken,
		});
		return;
	}

	const voided = notification.voidedPurchaseNotification;
	if (voided) {
		let refreshError: unknown = null;
		if (voided.purchaseToken) {
			try {
				await refreshGooglePlaySubscription({
					purchaseToken: voided.purchaseToken,
				});
			} catch (error) {
				if ((error as { code?: unknown }).code === 410) {
					const ref = db.collection("subscriptions").doc(voided.purchaseToken);
					const existing = await ref.get();
					await ref.set(
						{
							entitlementState: "ended",
							subscriptionState: "SUBSCRIPTION_STATE_REVOKED",
							updatedAt: FieldValue.serverTimestamp(),
							willAutoRenew: false,
						},
						{ merge: true },
					);
					const userId = existing.data()?.userId;
					if (typeof userId === "string") {
						await reconcileUserEntitlement(userId);
					}
				} else {
					refreshError = error;
				}
			}
		}
		if (voided.orderId) await syncGooglePlayOrderById(voided.orderId);
		if (refreshError) throw refreshError;
	}
}

export default onMessagePublished(
	{
		topic: "play-store-notifications",
		retry: true,
		secrets: [googlePlayCredentials],
		timeoutSeconds: 120,
	},
	async (event) => {
		const messageId = event.data.message.messageId || event.id;
		const notification = event.data.message.json as PlayNotification;
		await executeClaimedPlayEvent({
			claim: () => claimEvent(messageId),
			complete: () => completeEvent(messageId),
			process: async () => {
				logInfo("Processing Google Play developer notification", {
					event: "play_store_notification",
					messageId,
					...safePlayEventLogData(notification),
				});
				await processPlayNotification(notification);
			},
			fail: async (error) => {
				await failEvent(messageId, error);
				logError("Google Play developer notification failed", {
					event: "play_store_notification_failed",
					messageId,
					errorCode:
						typeof (error as { code?: unknown }).code === "string"
							? (error as { code: string }).code.slice(0, 120)
							: error instanceof Error
								? error.name.slice(0, 120)
								: "unknown",
				});
			},
		});
	},
);
