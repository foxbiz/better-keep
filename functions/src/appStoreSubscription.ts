export type AppStoreNotificationDecision =
	| {
			defaultWillAutoRenew: boolean;
			endEntitlementImmediately: boolean;
			kind: "state_change";
			subscriptionState: string;
	  }
	| { kind: "metadata_only" }
	| { kind: "unknown" };

const INFORMATIONAL_NOTIFICATION_TYPES = new Set([
	"DID_CHANGE_RENEWAL_PREF",
	"OFFER_REDEEMED",
	"PRICE_INCREASE",
	"RENEWAL_EXTENDED",
	"RENEWAL_EXTENSION",
]);

/**
 * Converts an App Store Server Notification into an entitlement decision.
 * Unknown events deliberately preserve the current entitlement so a newly
 * introduced Apple event cannot silently revoke customer access.
 */
export function resolveAppStoreNotification(
	notificationType: string,
	subtype: string | null,
): AppStoreNotificationDecision {
	if (notificationType === "SUBSCRIBED" || notificationType === "DID_RENEW") {
		return {
			kind: "state_change",
			subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
			defaultWillAutoRenew: true,
			endEntitlementImmediately: false,
		};
	}

	if (notificationType === "DID_FAIL_TO_RENEW") {
		return subtype === "GRACE_PERIOD"
			? {
					kind: "state_change",
					subscriptionState: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
					defaultWillAutoRenew: true,
					endEntitlementImmediately: false,
				}
			: {
					kind: "state_change",
					subscriptionState: "SUBSCRIPTION_STATE_PENDING",
					defaultWillAutoRenew: false,
					endEntitlementImmediately: false,
				};
	}

	if (notificationType === "EXPIRED") {
		return {
			kind: "state_change",
			subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
			defaultWillAutoRenew: false,
			endEntitlementImmediately: false,
		};
	}

	if (notificationType === "REFUND" || notificationType === "REVOKE") {
		return {
			kind: "state_change",
			subscriptionState: "SUBSCRIPTION_STATE_REVOKED",
			defaultWillAutoRenew: false,
			endEntitlementImmediately: true,
		};
	}

	if (notificationType === "DID_CHANGE_RENEWAL_STATUS") {
		if (subtype === "AUTO_RENEW_ENABLED") {
			return {
				kind: "state_change",
				subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
				defaultWillAutoRenew: true,
				endEntitlementImmediately: false,
			};
		}
		if (subtype === "AUTO_RENEW_DISABLED") {
			return {
				kind: "state_change",
				subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
				defaultWillAutoRenew: false,
				endEntitlementImmediately: false,
			};
		}
		return { kind: "unknown" };
	}

	if (INFORMATIONAL_NOTIFICATION_TYPES.has(notificationType)) {
		return { kind: "metadata_only" };
	}

	return { kind: "unknown" };
}

function validMillis(value: number | null | undefined): number | null {
	return typeof value === "number" && Number.isFinite(value) && value >= 0
		? value
		: null;
}

/**
 * Returns the effective expiry stored for a state-changing notification.
 * Refunds and revocations are capped at their authoritative termination time,
 * preventing an old future expiry from retaining access.
 */
export function appStoreEffectiveExpiryMillis({
	decision,
	existingExpiryMillis,
	notificationSignedDateMillis,
	now,
	providerExpiryMillis,
	revocationDateMillis,
}: {
	decision: AppStoreNotificationDecision;
	existingExpiryMillis?: number | null;
	notificationSignedDateMillis?: number | null;
	now: number;
	providerExpiryMillis?: number | null;
	revocationDateMillis?: number | null;
}): number | null {
	const providerExpiry =
		validMillis(providerExpiryMillis) ?? validMillis(existingExpiryMillis);
	if (decision.kind !== "state_change" || !decision.endEntitlementImmediately) {
		return providerExpiry;
	}

	const termination =
		validMillis(revocationDateMillis) ??
		validMillis(notificationSignedDateMillis) ??
		now;
	return providerExpiry === null
		? termination
		: Math.min(providerExpiry, termination);
}

export function appStoreWillAutoRenew(
	decision: AppStoreNotificationDecision,
	autoRenewStatus: number | null,
): boolean | null {
	if (decision.kind !== "state_change") return null;
	if (decision.endEntitlementImmediately) return false;
	if (autoRenewStatus === 1) return true;
	if (autoRenewStatus === 0) return false;
	return decision.defaultWillAutoRenew;
}
