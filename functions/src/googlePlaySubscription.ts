import { Timestamp } from "firebase-admin/firestore";
import { evaluateSubscription } from "./subscriptionEntitlement";

interface PlayLineItem {
	autoRenewingPlan?: { autoRenewEnabled?: boolean | null } | null;
	expiryTime?: string | null;
	offerDetails?: { basePlanId?: string | null; offerId?: string | null } | null;
	productId?: string | null;
}

export interface GooglePlaySubscriptionResource {
	acknowledgementState?: string | null;
	externalAccountIdentifiers?: {
		obfuscatedExternalAccountId?: string | null;
	};
	latestOrderId?: string | null;
	lineItems?: PlayLineItem[] | null;
	linkedPurchaseToken?: string | null;
	startTime?: string | null;
	subscriptionState?: string | null;
	testPurchase?: object | null;
}

function validDate(value: string | null | undefined): Date | null {
	if (!value) return null;
	const date = new Date(value);
	return Number.isNaN(date.getTime()) ? null : date;
}

function latestLineItem(
	lineItems: PlayLineItem[],
	productId?: string,
): PlayLineItem | null {
	const matching = productId
		? lineItems.filter((lineItem) => lineItem.productId === productId)
		: lineItems;
	const candidates = matching.length > 0 ? matching : lineItems;
	return (
		[...candidates].sort(
			(a, b) =>
				(validDate(b.expiryTime)?.getTime() ?? 0) -
				(validDate(a.expiryTime)?.getTime() ?? 0),
		)[0] ?? null
	);
}

export function normalizeGooglePlaySubscription({
	productId,
	purchaseToken,
	resource,
	userId,
	now = Date.now(),
}: {
	productId?: string;
	purchaseToken: string;
	resource: GooglePlaySubscriptionResource;
	userId: string | null;
	now?: number;
}): Record<string, unknown> {
	const lineItem = latestLineItem(resource.lineItems ?? [], productId);
	const expiry = validDate(lineItem?.expiryTime);
	const subscriptionState = resource.subscriptionState ?? null;
	const environment = resource.testPurchase ? "test" : "production";
	const autoRenewEnabled = lineItem?.autoRenewingPlan?.autoRenewEnabled;
	const baseData: Record<string, unknown> = {
		plan: "pro",
		source: "play_store",
		environment,
		userId,
		productId: lineItem?.productId ?? productId ?? null,
		purchaseToken,
		basePlanId: lineItem?.offerDetails?.basePlanId ?? null,
		offerId: lineItem?.offerDetails?.offerId ?? null,
		billingPeriod:
			lineItem?.offerDetails?.basePlanId === "pro-yearly"
				? "yearly"
				: "monthly",
		subscriptionState,
		renewalState:
			typeof autoRenewEnabled === "boolean"
				? autoRenewEnabled
					? "renewing"
					: "notRenewing"
				: "unknown",
		willAutoRenew:
			typeof autoRenewEnabled === "boolean" ? autoRenewEnabled : null,
		expiresAt: expiry ? Timestamp.fromDate(expiry) : null,
		latestOrderId: resource.latestOrderId ?? null,
		linkedPurchaseToken: resource.linkedPurchaseToken ?? null,
		acknowledgementState: resource.acknowledgementState ?? null,
		externalAccountId:
			resource.externalAccountIdentifiers?.obfuscatedExternalAccountId ?? null,
		externalAccountVerified:
			userId !== null &&
			resource.externalAccountIdentifiers?.obfuscatedExternalAccountId ===
				userId,
		startTime: validDate(resource.startTime)
			? Timestamp.fromDate(validDate(resource.startTime) as Date)
			: null,
	};
	const evaluated = evaluateSubscription(baseData, now);
	return {
		...baseData,
		entitlementState: evaluated.entitlementState,
	};
}

export function googlePlayAccountId(
	resource: GooglePlaySubscriptionResource,
): string | null {
	const value =
		resource.externalAccountIdentifiers?.obfuscatedExternalAccountId?.trim();
	return value ? value : null;
}
