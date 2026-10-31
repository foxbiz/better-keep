import { FieldValue } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
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

/** Deterministic provider identity failures require repair, not redelivery. */
export class GooglePlayPermanentError extends HttpsError {
	constructor(message: string) {
		super("failed-precondition", message);
	}
}

export interface RefreshedGooglePlaySubscription {
	data: Record<string, unknown>;
	entitled: boolean;
	expiresAt: Date | null;
	status: "linked" | "mismatch" | "unmatched";
	userId: string | null;
}

export function isGooglePlayGoneError(error: unknown): boolean {
	const candidate = error as {
		code?: unknown;
		response?: { status?: unknown };
	};
	return (
		Number(candidate?.code) === 410 ||
		Number(candidate?.response?.status) === 410
	);
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

export async function endUnqueryableGooglePlaySubscription(
	purchaseToken: string,
	reconcile = true,
): Promise<string | null> {
	const subscriptionRef = db.collection("subscriptions").doc(purchaseToken);
	const existing = await subscriptionRef.get();
	const data = existing.data() ?? {};
	const userId = typeof data.userId === "string" ? data.userId : null;
	if (existing.exists) {
		await subscriptionRef.set(
			{
				entitlementState: "ended",
				renewalState: "notRenewing",
				subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
				willAutoRenew: false,
				lastVerifiedAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);
	}
	await resolveSubscriptionIssues(purchaseToken, "play_store");
	if (userId && reconcile) await reconcileUserEntitlement(userId);
	return userId;
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
	let normalized = normalizeGooglePlaySubscription({
		productId,
		purchaseToken,
		resource,
		userId,
	});
	if (normalized.plan === "free") {
		throw new GooglePlayPermanentError(
			"Unsupported Google Play product or base plan.",
		);
	}
	const previousToken = resource.linkedPurchaseToken;
	if (
		previousToken &&
		(previousToken === purchaseToken || previousToken.includes("/"))
	) {
		throw new Error("Invalid Google Play replacement identity");
	}
	const previousRef = previousToken
		? db.collection("subscriptions").doc(previousToken)
		: null;
	// Publish the new purchase and retire its predecessor atomically. A missing
	// predecessor gets an ownership marker so a late restore cannot revive it.
	normalized = await db.runTransaction(async (transaction) => {
		const current = await transaction.get(subscriptionRef);
		const previous = previousRef ? await transaction.get(previousRef) : null;
		for (const record of [current, previous]) {
			if (record?.data()?.source && record.data()?.source !== "play_store") {
				throw new GooglePlayPermanentError("Conflicting purchase provider.");
			}
			const owner = record?.data()?.userId;
			if (owner && userId && owner !== userId) {
				throw new GooglePlayPermanentError(
					"This purchase belongs to another account.",
				);
			}
		}
		const currentData: Record<string, unknown> = {
			...normalized,
			...(current.data()?.supersededByPurchaseToken
				? {
						supersededByPurchaseToken:
							current.data()?.supersededByPurchaseToken,
					}
				: {}),
		};
		currentData.entitlementState =
			evaluateSubscription(currentData).entitlementState;
		if (previousRef && userId && evaluateSubscription(currentData).entitled) {
			const replacedBy = previous?.data()?.supersededByPurchaseToken;
			if (replacedBy && replacedBy !== purchaseToken) {
				throw new GooglePlayPermanentError(
					"This purchase already has a different replacement.",
				);
			}
			transaction.set(
				previousRef,
				{
					userId,
					source: "play_store",
					supersededByPurchaseToken: purchaseToken,
					entitlementState: "ended",
					updatedAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);
		}
		transaction.set(
			subscriptionRef,
			{
				...currentData,
				lastVerifiedAt: FieldValue.serverTimestamp(),
				...(!current.exists ? { createdAt: FieldValue.serverTimestamp() } : {}),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);
		return currentData;
	});
	const evaluated = evaluateSubscription(normalized);

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
