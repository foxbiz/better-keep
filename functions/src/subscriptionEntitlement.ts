import { Timestamp } from "firebase-admin/firestore";
import {
	PAID_SUBSCRIPTION_SOURCES,
	type PaidSubscriptionSource,
} from "./adminConfig";

export type SubscriptionEnvironment = "production" | "test" | "unknown";
export const ENTITLEMENT_CONTRACT_VERSION = 2 as const;
export type RenewalState = "notRenewing" | "renewing" | "unknown";
export type EntitlementState =
	| "cancelled_access"
	| "ended"
	| "entitled"
	| "grace"
	| "pending"
	| "suspended";

export interface EvaluatedSubscription {
	billingPeriod: string | null;
	entitled: boolean;
	entitlementState: EntitlementState;
	environment: SubscriptionEnvironment;
	expiresAt: Timestamp | null;
	plan: string;
	productionPaid: boolean;
	renewalState: RenewalState;
	renews: boolean;
	source: string | null;
	state: string | null;
}

type TimestampLike = {
	toDate?: () => Date;
	toMillis?: () => number;
};

export function subscriptionTimestamp(value: unknown): Timestamp | null {
	if (value instanceof Timestamp) return value;
	if (!value || typeof value !== "object") return null;
	const candidate = value as TimestampLike;
	if (typeof candidate.toMillis === "function") {
		const millis = candidate.toMillis();
		if (Number.isFinite(millis)) return Timestamp.fromMillis(millis);
	}
	if (typeof candidate.toDate === "function") {
		const date = candidate.toDate();
		if (!Number.isNaN(date.getTime())) return Timestamp.fromDate(date);
	}
	return null;
}

function text(value: unknown): string | null {
	return typeof value === "string" && value.trim().length > 0
		? value.trim()
		: null;
}

export function isPaidSubscriptionSource(
	source: string | null,
): source is PaidSubscriptionSource {
	return (
		source !== null &&
		(PAID_SUBSCRIPTION_SOURCES as readonly string[]).includes(source)
	);
}

export function subscriptionEnvironment(
	value: unknown,
): SubscriptionEnvironment {
	const normalized = text(value)?.toLowerCase();
	if (normalized === "production" || normalized === "live") {
		return "production";
	}
	if (
		normalized === "test" ||
		normalized === "sandbox" ||
		normalized === "license_test"
	) {
		return "test";
	}
	return "unknown";
}

function providerState(value: string | null): string | null {
	return value?.trim().toUpperCase() ?? null;
}

function isGrace(state: string | null): boolean {
	return state === "SUBSCRIPTION_STATE_IN_GRACE_PERIOD" || state === "GRACE";
}

function isCancelled(state: string | null): boolean {
	return (
		state === "SUBSCRIPTION_STATE_CANCELED" ||
		state === "CANCELED" ||
		state === "CANCELLED"
	);
}

function isActive(state: string | null): boolean {
	return state === "SUBSCRIPTION_STATE_ACTIVE" || state === "ACTIVE";
}

function isPending(state: string | null): boolean {
	return (
		state === "SUBSCRIPTION_STATE_PENDING" ||
		state === "PENDING" ||
		state === "PENDING_PURCHASE"
	);
}

function isSuspended(state: string | null): boolean {
	return (
		state === "SUBSCRIPTION_STATE_ON_HOLD" ||
		state === "SUBSCRIPTION_STATE_PAUSED" ||
		state === "ON_HOLD" ||
		state === "HALTED" ||
		state === "PAUSED"
	);
}

export function evaluateSubscription(
	data: Record<string, unknown> | null | undefined,
	now = Date.now(),
): EvaluatedSubscription {
	if (!data) {
		return {
			billingPeriod: null,
			entitled: false,
			entitlementState: "ended",
			environment: "unknown",
			expiresAt: null,
			plan: "free",
			productionPaid: false,
			renewalState: "unknown",
			renews: false,
			source: null,
			state: null,
		};
	}

	const source = text(data.source ?? data.purchasePlatform);
	const plan = text(data.plan) ?? "free";
	const rawState = text(data.subscriptionState ?? data.status);
	const state = providerState(rawState);
	const billingPeriod = text(data.billingPeriod ?? data.basePlanId);
	const expiresAt = subscriptionTimestamp(data.expiresAt ?? data.expiryDate);
	const future = expiresAt !== null && expiresAt.toMillis() > now;
	const stateAllowsAccess =
		state === null || isActive(state) || isGrace(state) || isCancelled(state);
	const entitled = plan === "pro" && future && stateAllowsAccess;

	let entitlementState: EntitlementState;
	if (entitled && isGrace(state)) entitlementState = "grace";
	else if (entitled && isCancelled(state))
		entitlementState = "cancelled_access";
	else if (entitled) entitlementState = "entitled";
	else if (isSuspended(state)) entitlementState = "suspended";
	else if (isPending(state)) entitlementState = "pending";
	else entitlementState = "ended";

	const rawRenewalState = text(data.renewalState);
	const explicitRenewalState: RenewalState | null =
		rawRenewalState === "renewing" ||
		rawRenewalState === "notRenewing" ||
		rawRenewalState === "unknown"
			? rawRenewalState
			: null;
	const explicitRenewal = data.willAutoRenew ?? data.autoRenew;
	const renewalState: RenewalState = explicitRenewalState
		? explicitRenewalState
		: typeof explicitRenewal === "boolean"
			? explicitRenewal
				? "renewing"
				: "notRenewing"
			: isCancelled(state)
				? "notRenewing"
				: "unknown";
	const renews = entitled && !isCancelled(state) && renewalState === "renewing";
	const environment = subscriptionEnvironment(data.environment);

	return {
		billingPeriod,
		entitled,
		entitlementState,
		environment,
		expiresAt,
		plan,
		productionPaid:
			entitled &&
			isPaidSubscriptionSource(source) &&
			environment === "production",
		renewalState,
		renews,
		source,
		state: rawState,
	};
}

export function normalizedSubscriptionFields(
	data: Record<string, unknown>,
	now = Date.now(),
): Record<string, unknown> {
	const evaluated = evaluateSubscription(data, now);
	return {
		plan: evaluated.plan,
		source: evaluated.source,
		environment: evaluated.environment,
		billingPeriod: evaluated.billingPeriod,
		subscriptionState: evaluated.state,
		entitlementState: evaluated.entitlementState,
		renewalState: evaluated.renewalState,
		willAutoRenew:
			evaluated.renewalState === "unknown" ? null : evaluated.renews,
		...(evaluated.expiresAt ? { expiresAt: evaluated.expiresAt } : {}),
	};
}

export interface VerifiedEntitlementPayload {
	billingPeriod: string;
	entitlementContractVersion: typeof ENTITLEMENT_CONTRACT_VERSION;
	expiresAt: string;
	plan: "pro";
	renewalState: RenewalState;
	source: PaidSubscriptionSource;
	subscriptionState: string;
	willAutoRenew: boolean | null;
}

/**
 * Produces the single response contract consumed by every purchase and restore
 * path. Returning null prevents an inactive or malformed provider record from
 * being accidentally hydrated as paid access on the client.
 */
export function verifiedEntitlementPayload(
	data: Record<string, unknown> | null | undefined,
	now = Date.now(),
): VerifiedEntitlementPayload | null {
	const evaluated = evaluateSubscription(data, now);
	if (
		!evaluated.entitled ||
		!evaluated.expiresAt ||
		!evaluated.billingPeriod ||
		!isPaidSubscriptionSource(evaluated.source)
	) {
		return null;
	}

	return {
		billingPeriod: evaluated.billingPeriod,
		entitlementContractVersion: ENTITLEMENT_CONTRACT_VERSION,
		expiresAt: evaluated.expiresAt.toDate().toISOString(),
		plan: "pro",
		renewalState: evaluated.renewalState,
		source: evaluated.source,
		subscriptionState: evaluated.state ?? evaluated.entitlementState,
		willAutoRenew:
			evaluated.renewalState === "unknown" ? null : evaluated.renews,
	};
}

export function requireVerifiedEntitlementPayload(
	data: Record<string, unknown> | null | undefined,
	now = Date.now(),
): VerifiedEntitlementPayload {
	const payload = verifiedEntitlementPayload(data, now);
	if (!payload) {
		throw new Error("Active provider entitlement is incomplete");
	}
	return payload;
}
