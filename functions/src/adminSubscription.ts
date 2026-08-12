import { Timestamp } from "firebase-admin/firestore";
import {
	evaluateSubscription,
	normalizedSubscriptionFields,
} from "./subscriptionEntitlement";

export type AdminSubscriptionClass = "free" | "paid" | "trial";
export type AdminRenewalState = "cancelled" | "none" | "renewing";

export interface AdminSubscriptionSummary {
	billingPeriod: string | null;
	entitlementState: string;
	environment: string;
	expiresAt: Timestamp | null;
	plan: string;
	renewalState: AdminRenewalState;
	source: string | null;
	state: string | null;
	subscriptionClass: AdminSubscriptionClass;
}

export function summarizeSubscription(
	data: Record<string, unknown> | null | undefined,
	now = Date.now(),
): AdminSubscriptionSummary {
	if (!data) {
		return {
			billingPeriod: null,
			entitlementState: "ended",
			environment: "unknown",
			expiresAt: null,
			plan: "free",
			renewalState: "none",
			source: null,
			state: null,
			subscriptionClass: "free",
		};
	}

	const evaluated = evaluateSubscription(data, now);

	let subscriptionClass: AdminSubscriptionClass = "free";
	if (evaluated.entitled && evaluated.source === "trial") {
		subscriptionClass = "trial";
	} else if (
		evaluated.productionPaid ||
		(evaluated.entitled && data.hasProductionPaidEntitlement === true)
	) {
		subscriptionClass = "paid";
	}

	const renewalState: AdminRenewalState =
		subscriptionClass !== "paid"
			? "none"
			: (
						typeof data.hasRenewingPaidEntitlement === "boolean"
							? data.hasRenewingPaidEntitlement
							: evaluated.renews
					)
				? "renewing"
				: "cancelled";

	return {
		billingPeriod: evaluated.billingPeriod,
		entitlementState: evaluated.entitlementState,
		environment: evaluated.environment,
		expiresAt: evaluated.expiresAt,
		plan: evaluated.plan,
		renewalState,
		source: evaluated.source,
		state: evaluated.state,
		subscriptionClass,
	};
}

export function canonicalSubscriptionFields(
	data: Record<string, unknown>,
): Record<string, unknown> {
	return normalizedSubscriptionFields(data);
}
