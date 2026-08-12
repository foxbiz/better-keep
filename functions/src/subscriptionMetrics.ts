import { PAID_SUBSCRIPTION_SOURCES } from "./adminConfig";
import { evaluateSubscription } from "./subscriptionEntitlement";

export type ProviderSubscriptionCounts = {
	cancelledWithAccess: number;
	entitled: number;
	grace: number;
	renewing: number;
	suspended: number;
	unmatched: number;
};

export function emptyProviderSubscriptionCounts(): Record<
	string,
	ProviderSubscriptionCounts
> {
	return Object.fromEntries(
		PAID_SUBSCRIPTION_SOURCES.map((source) => [
			source,
			{
				cancelledWithAccess: 0,
				entitled: 0,
				grace: 0,
				renewing: 0,
				suspended: 0,
				unmatched: 0,
			},
		]),
	) as Record<string, ProviderSubscriptionCounts>;
}

export function providerSubscriptionCounts(
	documents: Array<Record<string, unknown>>,
): Record<string, ProviderSubscriptionCounts> {
	const counts = emptyProviderSubscriptionCounts();
	for (const data of documents) {
		const evaluated = evaluateSubscription(data);
		if (!evaluated.source || !(evaluated.source in counts)) continue;
		if (evaluated.environment !== "production") continue;
		const provider = counts[evaluated.source];
		if (evaluated.entitled) provider.entitled += 1;
		if (evaluated.renews) provider.renewing += 1;
		if (evaluated.entitlementState === "cancelled_access") {
			provider.cancelledWithAccess += 1;
		}
		if (evaluated.entitlementState === "grace") provider.grace += 1;
		if (evaluated.entitlementState === "suspended") provider.suspended += 1;
	}
	return counts;
}

export function storedProviderSubscriptionCounts(
	value: unknown,
): Record<string, ProviderSubscriptionCounts> {
	const counts = emptyProviderSubscriptionCounts();
	if (!value || typeof value !== "object") return counts;
	for (const [source, target] of Object.entries(counts)) {
		const raw = (value as Record<string, unknown>)[source];
		if (!raw || typeof raw !== "object") continue;
		for (const key of Object.keys(target) as Array<
			keyof ProviderSubscriptionCounts
		>) {
			target[key] = Math.max(
				0,
				Math.floor(Number((raw as Record<string, unknown>)[key]) || 0),
			);
		}
	}
	return counts;
}
