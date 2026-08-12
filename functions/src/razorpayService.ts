import { FieldValue } from "firebase-admin/firestore";
import { db } from "./config";
import {
	normalizeRazorpaySubscription,
	type RazorpaySubscriptionEntity,
} from "./razorpaySubscription";
import { evaluateSubscription } from "./subscriptionEntitlement";
import { reconcileUserEntitlement } from "./subscriptionReconciler";
import { razorpayRequest } from "./utils";

export async function findUserRazorpaySubscription(userId: string): Promise<{
	data: Record<string, unknown>;
	ref: FirebaseFirestore.DocumentReference;
} | null> {
	const snapshot = await db
		.collection("subscriptions")
		.where("userId", "==", userId)
		.where("source", "==", "razorpay")
		.get();
	const candidates = snapshot.docs
		.map((document) => ({
			data: document.data(),
			evaluated: evaluateSubscription(document.data()),
			ref: document.ref,
		}))
		.sort(
			(a, b) =>
				(b.evaluated.expiresAt?.toMillis() ?? 0) -
				(a.evaluated.expiresAt?.toMillis() ?? 0),
		);
	return candidates[0] ?? null;
}

export async function refreshRazorpaySubscriptionRecord({
	billingPeriod,
	keyId,
	keySecret,
	subscriptionId,
	userId,
}: {
	billingPeriod?: string | null;
	keyId: string;
	keySecret: string;
	subscriptionId: string;
	userId: string;
}): Promise<Record<string, unknown>> {
	const entity = (await razorpayRequest(
		keyId,
		keySecret,
		"GET",
		`/subscriptions/${encodeURIComponent(subscriptionId)}`,
	)) as RazorpaySubscriptionEntity;
	if (entity.id !== subscriptionId) {
		throw new Error("Razorpay returned a different subscription");
	}
	return persistVerifiedRazorpaySubscriptionRecord({
		billingPeriod,
		entity,
		userId,
	});
}

export async function persistVerifiedRazorpaySubscriptionRecord({
	billingPeriod,
	entity,
	reconcile = true,
	userId,
}: {
	billingPeriod?: string | null;
	entity: RazorpaySubscriptionEntity;
	reconcile?: boolean;
	userId: string;
}): Promise<Record<string, unknown>> {
	const normalized = normalizeRazorpaySubscription({
		billingPeriod,
		entity,
		userId,
	});
	await db
		.collection("subscriptions")
		.doc(`razorpay_${entity.id}`)
		.set(
			{
				...normalized,
				lastVerifiedAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);
	if (reconcile) await reconcileUserEntitlement(userId);
	return normalized;
}
