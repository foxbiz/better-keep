import { FieldValue } from "firebase-admin/firestore";
import { google } from "googleapis";
import {
	ANDROID_PACKAGE_NAME,
	auth,
	db,
	googlePlayCredentials,
} from "./config";
import {
	type GooglePlaySubscriptionResource,
	googlePlayAccountId,
	normalizeGooglePlaySubscription,
} from "./googlePlaySubscription";
import { evaluateSubscription } from "./subscriptionEntitlement";
import {
	recordSubscriptionIssue,
	resolveSubscriptionIssues,
} from "./subscriptionIssues";
import { reconcileUserEntitlement } from "./subscriptionReconciler";

export interface RefreshedGooglePlaySubscription {
	data: Record<string, unknown>;
	entitled: boolean;
	expiresAt: Date | null;
	status: "linked" | "mismatch" | "unmatched";
	userId: string | null;
}

async function publisherApi() {
	const credentials = JSON.parse(googlePlayCredentials.value());
	return google.androidpublisher({
		version: "v3",
		auth: new google.auth.GoogleAuth({
			credentials,
			scopes: ["https://www.googleapis.com/auth/androidpublisher"],
		}),
	});
}

async function authUserExists(userId: string): Promise<boolean> {
	try {
		await auth.getUser(userId);
		return true;
	} catch (error) {
		if ((error as { code?: unknown }).code === "auth/user-not-found")
			return false;
		throw error;
	}
}

export async function verifiedFirebaseUserId(
	userId: string | null,
	userExists: (uid: string) => Promise<boolean> = authUserExists,
): Promise<string | null> {
	if (!userId) return null;
	return (await userExists(userId)) ? userId : null;
}

export async function getGooglePlaySubscription(
	purchaseToken: string,
): Promise<GooglePlaySubscriptionResource> {
	const api = await publisherApi();
	const response = await api.purchases.subscriptionsv2.get({
		packageName: ANDROID_PACKAGE_NAME,
		token: purchaseToken,
	});
	if (!response.data) throw new Error("Google Play subscription was not found");
	return response.data;
}

export async function refreshGooglePlaySubscription({
	productId,
	purchaseToken,
	requestedUserId = null,
}: {
	productId?: string;
	purchaseToken: string;
	requestedUserId?: string | null;
}): Promise<RefreshedGooglePlaySubscription> {
	const resource = await getGooglePlaySubscription(purchaseToken);
	return persistVerifiedGooglePlaySubscription({
		productId,
		purchaseToken,
		requestedUserId,
		resource,
	});
}

export async function persistVerifiedGooglePlaySubscription({
	productId,
	purchaseToken,
	reconcile = true,
	requestedUserId = null,
	resource,
	userExists = authUserExists,
}: {
	productId?: string;
	purchaseToken: string;
	reconcile?: boolean;
	requestedUserId?: string | null;
	resource: GooglePlaySubscriptionResource;
	userExists?: (uid: string) => Promise<boolean>;
}): Promise<RefreshedGooglePlaySubscription> {
	const subscriptionRef = db.collection("subscriptions").doc(purchaseToken);
	const existing = await subscriptionRef.get();
	const oldUserId =
		typeof existing.data()?.userId === "string"
			? (existing.data()?.userId as string)
			: null;
	const externalAccountId = googlePlayAccountId(resource);
	if (oldUserId && externalAccountId && externalAccountId !== oldUserId) {
		await recordSubscriptionIssue({
			type: "play_owner_changed",
			source: "play_store",
			providerKey: purchaseToken,
			userId: oldUserId,
			details: { externalAccountPresent: true },
		});
		return {
			data: existing.data() ?? {},
			entitled: false,
			expiresAt: null,
			status: "mismatch",
			userId: oldUserId,
		};
	}

	if (
		requestedUserId &&
		externalAccountId !== requestedUserId &&
		!(externalAccountId === null && oldUserId === requestedUserId)
	) {
		await recordSubscriptionIssue({
			type: "play_account_mismatch",
			source: "play_store",
			providerKey: purchaseToken,
			userId: requestedUserId,
			details: {
				externalAccountPresent: externalAccountId !== null,
				existingOwnerPresent: oldUserId !== null,
			},
		});
		return {
			data: {},
			entitled: false,
			expiresAt: null,
			status: "mismatch",
			userId: null,
		};
	}

	const userId = await verifiedFirebaseUserId(
		requestedUserId ?? externalAccountId ?? oldUserId,
		userExists,
	);
	const normalized = normalizeGooglePlaySubscription({
		productId,
		purchaseToken,
		resource,
		userId,
	});
	const evaluated = evaluateSubscription(normalized);

	await subscriptionRef.set(
		{
			...normalized,
			lastVerifiedAt: FieldValue.serverTimestamp(),
			...(!existing.exists ? { createdAt: FieldValue.serverTimestamp() } : {}),
			updatedAt: FieldValue.serverTimestamp(),
		},
		{ merge: true },
	);

	if (!userId) {
		await recordSubscriptionIssue({
			type: "play_unmatched_purchase",
			source: "play_store",
			providerKey: purchaseToken,
			details: {
				externalAccountPresent: externalAccountId !== null,
			},
		});
		return {
			data: normalized,
			entitled: evaluated.entitled,
			expiresAt: evaluated.expiresAt?.toDate() ?? null,
			status: "unmatched",
			userId: null,
		};
	}

	if (reconcile) {
		await reconcileUserEntitlement(userId);
		if (oldUserId && oldUserId !== userId) {
			await reconcileUserEntitlement(oldUserId);
		}
	}
	await resolveSubscriptionIssues(purchaseToken, "play_store");
	return {
		data: normalized,
		entitled: evaluated.entitled,
		expiresAt: evaluated.expiresAt?.toDate() ?? null,
		status: "linked",
		userId,
	};
}
