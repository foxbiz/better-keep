import { createHash } from "node:crypto";
import { Timestamp } from "firebase-admin/firestore";
import {
	ADMIN_BILLING_ACTIVITY_COLLECTION,
	type PaidSubscriptionSource,
} from "./adminConfig";
import { db } from "./config";

export const BILLING_ACTIVITY_TYPES = [
	"purchase",
	"renewal",
	"recovery",
	"restart",
	"cancellation",
	"grace",
	"hold",
	"pause",
	"deferred",
	"plan_change",
	"revocation",
	"expiration",
	"charge",
	"refund",
	"state_change",
] as const;

export type BillingActivityType = (typeof BILLING_ACTIVITY_TYPES)[number];
export type BillingActivityOrigin = "live" | "historical";

export interface BillingActivityInput {
	amountMicros?: number | null;
	billingPeriod?: string | null;
	currency?: string | null;
	entitlementState?: string | null;
	environment?: string | null;
	eventKey: string;
	eventType: BillingActivityType;
	occurredAt: Date;
	origin?: BillingActivityOrigin;
	productId?: string | null;
	provider: PaidSubscriptionSource;
	revenueEventId?: string | null;
	revenueKind?: "charge" | "refund" | null;
	revenueStatus?: string | null;
	subscriptionState?: string | null;
	userId?: string | null;
}

export function historicalPlayChargeType(
	startTime: string | null | undefined,
	chargedAt: Date,
): BillingActivityType {
	const startedAt = startTime ? new Date(startTime) : null;
	return startedAt &&
		!Number.isNaN(startedAt.getTime()) &&
		Math.abs(chargedAt.getTime() - startedAt.getTime()) <= 24 * 60 * 60 * 1000
		? "purchase"
		: "renewal";
}

export function billingActivityId(
	provider: PaidSubscriptionSource,
	eventKey: string,
): string {
	return createHash("sha256").update(`${provider}\0${eventKey}`).digest("hex");
}

export function playBillingActivityType(
	notificationType: number | null | undefined,
): BillingActivityType {
	switch (notificationType) {
		case 1:
			return "recovery";
		case 2:
			return "renewal";
		case 3:
		case 18:
			return "cancellation";
		case 4:
			return "purchase";
		case 5:
			return "hold";
		case 6:
			return "grace";
		case 7:
			return "restart";
		case 9:
			return "deferred";
		case 10:
		case 11:
			return "pause";
		case 12:
			return "revocation";
		case 13:
		case 20:
			return "expiration";
		case 17:
		case 19:
		case 22:
			return "plan_change";
		default:
			return "state_change";
	}
}

export function appStoreBillingActivityType(
	notificationType: string,
	subtype: string | null,
): BillingActivityType {
	if (notificationType === "SUBSCRIBED") {
		return subtype === "RESUBSCRIBE" ? "restart" : "purchase";
	}
	if (notificationType === "DID_RENEW") return "renewal";
	if (notificationType === "DID_RECOVER") return "recovery";
	if (notificationType === "REFUND") return "refund";
	if (notificationType === "REVOKE") return "revocation";
	if (
		notificationType === "EXPIRED" ||
		notificationType === "GRACE_PERIOD_EXPIRED"
	) {
		return "expiration";
	}
	if (notificationType === "DID_FAIL_TO_RENEW") {
		return subtype === "GRACE_PERIOD" ? "grace" : "hold";
	}
	if (notificationType === "DID_CHANGE_RENEWAL_STATUS") {
		return subtype === "AUTO_RENEW_DISABLED" ? "cancellation" : "restart";
	}
	if (
		notificationType === "DID_CHANGE_RENEWAL_PREF" ||
		notificationType === "PRICE_INCREASE"
	) {
		return "plan_change";
	}
	return "state_change";
}

export function razorpayBillingActivityType(
	eventName: string,
	hasPayment: boolean,
): BillingActivityType {
	if (eventName.includes("refund")) return "refund";
	if (eventName === "subscription.authenticated") return "purchase";
	if (hasPayment || eventName === "subscription.charged") return "renewal";
	if (eventName === "subscription.cancelled") return "cancellation";
	if (eventName === "subscription.paused") return "pause";
	if (eventName === "subscription.resumed") return "restart";
	if (eventName === "subscription.halted") return "hold";
	if (eventName === "subscription.completed") return "expiration";
	return "state_change";
}

export function billingActivityData(
	input: BillingActivityInput,
	now = Timestamp.now(),
): Record<string, unknown> {
	if (!input.eventKey.trim())
		throw new Error("Billing activity event key is required");
	if (Number.isNaN(input.occurredAt.getTime())) {
		throw new Error("Billing activity occurrence date is invalid");
	}
	const amountMicros = input.amountMicros ?? null;
	if (
		amountMicros !== null &&
		(!Number.isSafeInteger(amountMicros) || amountMicros < 0)
	) {
		throw new Error("Billing activity amount must be a non-negative integer");
	}
	const currency = input.currency?.trim().toUpperCase() || null;
	if ((amountMicros === null) !== (currency === null)) {
		throw new Error(
			"Billing activity amount and currency must be supplied together",
		);
	}
	if (currency !== null && !/^[A-Z]{3}$/.test(currency)) {
		throw new Error("Billing activity currency must be an ISO currency code");
	}
	return {
		provider: input.provider,
		eventType: input.eventType,
		occurredAt: Timestamp.fromDate(input.occurredAt),
		origin: input.origin ?? "live",
		userId: input.userId ?? null,
		billingPeriod: input.billingPeriod ?? null,
		productId: input.productId ?? null,
		environment: input.environment ?? "unknown",
		subscriptionState: input.subscriptionState ?? null,
		entitlementState: input.entitlementState ?? null,
		amountMicros,
		currency,
		revenueKind: input.revenueKind ?? null,
		revenueEventId: input.revenueEventId ?? null,
		revenueStatus: input.revenueStatus ?? null,
		createdAt: now,
		updatedAt: now,
	};
}

export function writeBillingActivity(
	writer: Pick<FirebaseFirestore.Transaction, "set">,
	input: BillingActivityInput,
): string {
	const id = billingActivityId(input.provider, input.eventKey);
	writer.set(
		db.collection(ADMIN_BILLING_ACTIVITY_COLLECTION).doc(id),
		billingActivityData(input),
		{ merge: true },
	);
	return id;
}

export async function recordBillingActivity(
	input: BillingActivityInput,
): Promise<string> {
	const id = billingActivityId(input.provider, input.eventKey);
	await db
		.collection(ADMIN_BILLING_ACTIVITY_COLLECTION)
		.doc(id)
		.set(billingActivityData(input), { merge: true });
	return id;
}
