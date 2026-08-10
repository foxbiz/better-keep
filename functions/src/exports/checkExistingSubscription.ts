import { FieldValue } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { db, googlePlayCredentials } from "../config";
import { refreshGooglePlaySubscription } from "../googlePlayService";
import {
	type AuthenticatedCallableRequest,
	onNonReviewCall,
} from "../nonReviewCallable";
import {
	ENTITLEMENT_CONTRACT_VERSION,
	evaluateSubscription,
	verifiedEntitlementPayload,
} from "../subscriptionEntitlement";
import {
	type ReconciledEntitlement,
	reconcileUserEntitlement,
} from "../subscriptionReconciler";
import type { CheckSubscriptionRequest } from "../types";

export function existingSubscriptionResponse(
	data: Record<string, unknown> | undefined,
	now = Date.now(),
	reconciled?: ReconciledEntitlement,
): Record<string, unknown> {
	const evaluated = evaluateSubscription(data, now);
	const verified = verifiedEntitlementPayload(data, now);
	if (verified) {
		return {
			entitlementContractVersion: ENTITLEMENT_CONTRACT_VERSION,
			hasSubscription: true,
			resolution: "active_provider",
			subscription: verified,
		};
	}

	if (
		reconciled?.resolution === "provider_inactive" ||
		(!evaluated.entitled &&
			evaluated.source !== null &&
			evaluated.source !== "trial")
	) {
		return {
			entitlementContractVersion: ENTITLEMENT_CONTRACT_VERSION,
			entitlementState:
				reconciled?.entitlementState ?? evaluated.entitlementState,
			expiresAt:
				reconciled?.expiresAt?.toDate().toISOString() ??
				evaluated.expiresAt?.toDate().toISOString() ??
				null,
			hasSubscription: false,
			providerState: reconciled?.providerState ?? evaluated.state,
			renewalState: reconciled?.renewalState ?? evaluated.renewalState,
			resolution: "provider_inactive",
			source: reconciled?.primarySource ?? evaluated.source,
		};
	}

	if (
		reconciled?.resolution === "trial" ||
		(evaluated.entitled && evaluated.source === "trial")
	) {
		return {
			entitlementContractVersion: ENTITLEMENT_CONTRACT_VERSION,
			hasSubscription: false,
			isTrial: true,
			resolution: "trial",
		};
	}

	return {
		entitlementContractVersion: ENTITLEMENT_CONTRACT_VERSION,
		hasSubscription: false,
		resolution: "none",
	};
}

async function refreshLinkedPlaySubscriptions(userId: string): Promise<void> {
	const snapshot = await db
		.collection("subscriptions")
		.where("userId", "==", userId)
		.where("source", "==", "play_store")
		.get();
	for (const document of snapshot.docs) {
		const data = document.data();
		const purchaseToken =
			typeof data.purchaseToken === "string" ? data.purchaseToken : document.id;
		try {
			await refreshGooglePlaySubscription({
				purchaseToken,
				requestedUserId: userId,
			});
		} catch (error) {
			if ((error as { code?: unknown }).code !== 410) throw error;
			await document.ref.set(
				{
					subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
					entitlementState: "ended",
					renewalState: "notRenewing",
					willAutoRenew: false,
					updatedAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);
		}
	}
}

export default onNonReviewCall(
	{ secrets: [googlePlayCredentials] },
	async (request: AuthenticatedCallableRequest<CheckSubscriptionRequest>) => {
		const userId = request.auth.uid;
		const statusRef = db
			.collection("users")
			.doc(userId)
			.collection("subscription")
			.doc("status");
		try {
			// Always refresh provider records before deciding this is still a trial.
			// A verified provider must immediately replace trial as canonical status.
			await refreshLinkedPlaySubscriptions(userId);
			const reconciled = await reconcileUserEntitlement(userId);
			const after = await statusRef.get();
			return existingSubscriptionResponse(after.data(), Date.now(), reconciled);
		} catch (error) {
			console.error(`Error checking subscription for ${userId}:`, error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to check subscription status");
		}
	},
);
