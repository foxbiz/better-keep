import { createHash } from "node:crypto";
import { FieldValue } from "firebase-admin/firestore";
import { error as logError, info as logInfo } from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import {
	ADMIN_METRICS_COLLECTION,
	ADMIN_SUBSCRIPTION_ISSUE_COLLECTION,
} from "../adminConfig";
import { db, googlePlayCredentials } from "../config";
import { refreshGooglePlaySubscription } from "../googlePlayService";
import { reconcileUserEntitlement } from "../subscriptionReconciler";
import { recordSubscriptionIssue } from "../subscriptionIssues";
import { providerSubscriptionCounts } from "../subscriptionMetrics";

const BATCH_SIZE = 20;

function errorCode(error: unknown): string {
	const code = (error as { code?: unknown }).code;
	return typeof code === "string" || typeof code === "number"
		? String(code).slice(0, 120)
		: error instanceof Error
			? error.name.slice(0, 120)
			: "unknown";
}

export async function reconcileAllProviderSubscriptions(): Promise<{
	failures: number;
	playSubscriptions: number;
	users: number;
}> {
	const snapshot = await db.collection("subscriptions").get();
	const playDocuments = snapshot.docs.filter(
		(document) => document.data().source === "play_store",
	);
	const userIds = new Set<string>();
	let failures = 0;

	for (let offset = 0; offset < playDocuments.length; offset += BATCH_SIZE) {
		const batch = playDocuments.slice(offset, offset + BATCH_SIZE);
		await Promise.all(
			batch.map(async (document) => {
				const data = document.data();
				const purchaseToken =
					typeof data.purchaseToken === "string"
						? data.purchaseToken
						: document.id;
				try {
					const refreshed = await refreshGooglePlaySubscription({
						purchaseToken,
					});
					if (refreshed.userId) userIds.add(refreshed.userId);
				} catch (error) {
					failures += 1;
					if (typeof data.userId === "string") userIds.add(data.userId);
					await recordSubscriptionIssue({
						details: { errorCode: errorCode(error) },
						providerKey: purchaseToken,
						source: "play_store",
						type: "play_verification_failed",
						userId: typeof data.userId === "string" ? data.userId : null,
					});
					logError("Google Play subscription reconciliation failed", {
						subscriptionRecordHash: createHash("sha256")
							.update(document.id)
							.digest("hex")
							.slice(0, 16),
						errorCode: errorCode(error),
						event: "play_subscription_reconciliation_failed",
					});
				}
			}),
		);
	}

	for (const document of snapshot.docs) {
		const userId = document.data().userId;
		if (typeof userId === "string") userIds.add(userId);
	}
	for (const userId of userIds) await reconcileUserEntitlement(userId);
	const [updatedSubscriptions, openIssues] = await Promise.all([
		db.collection("subscriptions").get(),
		db
			.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
			.where("status", "==", "open")
			.get(),
	]);
	const providerCounts = providerSubscriptionCounts(
		updatedSubscriptions.docs.map((document) => document.data()),
	);
	for (const issue of openIssues.docs) {
		const source = issue.data().source;
		if (typeof source === "string" && providerCounts[source]) {
			providerCounts[source].unmatched += 1;
		}
	}

	await db
		.collection(ADMIN_METRICS_COLLECTION)
		.doc("current")
		.set(
			{
				subscriptionProviderCounts: providerCounts,
				subscriptionMetricsUpdatedAt: FieldValue.serverTimestamp(),
				subscriptionReconciliation: {
					failures,
					playSubscriptions: playDocuments.length,
					status: failures === 0 ? "ready" : "degraded",
					users: userIds.size,
					updatedAt: FieldValue.serverTimestamp(),
				},
			},
			{ merge: true },
		);

	if (failures > 0) {
		throw new Error(`${failures} provider subscriptions failed reconciliation`);
	}
	return {
		failures,
		playSubscriptions: playDocuments.length,
		users: userIds.size,
	};
}

export default onSchedule(
	{
		retryCount: 3,
		schedule: "every 6 hours",
		secrets: [googlePlayCredentials],
		timeZone: "Etc/UTC",
		timeoutSeconds: 540,
	},
	async () => {
		const result = await reconcileAllProviderSubscriptions();
		logInfo("Provider subscription reconciliation completed", {
			event: "provider_subscription_reconciliation_completed",
			...result,
		});
	},
);
