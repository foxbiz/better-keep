import { Timestamp } from "firebase-admin/firestore";
import {
	PAID_SUBSCRIPTION_SOURCES,
	type PaidSubscriptionSource,
} from "./adminConfig";
import {
	type BillingActivityType,
	recordBillingActivity,
} from "./billingActivity";
import { forEachBounded } from "./boundedConcurrency";
import { db } from "./config";

const BACKFILL_CONCURRENCY = 20;

function dateValue(value: unknown): Date | null {
	return value instanceof Timestamp ? value.toDate() : null;
}

function historicalSubscriptionType(
	data: Record<string, unknown>,
): BillingActivityType {
	const state = String(data.subscriptionState ?? "").toUpperCase();
	if (state.includes("REVOK")) return "revocation";
	if (state.includes("EXPIRED") || data.entitlementState === "ended") {
		return "expiration";
	}
	if (state.includes("CANCEL")) return "cancellation";
	if (state.includes("GRACE")) return "grace";
	if (state.includes("HOLD") || data.entitlementState === "suspended") {
		return "hold";
	}
	return "state_change";
}

function paidProvider(value: unknown): value is PaidSubscriptionSource {
	return (
		typeof value === "string" &&
		(PAID_SUBSCRIPTION_SOURCES as readonly string[]).includes(value)
	);
}

export async function backfillAdminBillingActivities(): Promise<{
	revenue: number;
	skipped: number;
	subscriptions: number;
}> {
	const [revenueSnapshot, subscriptionSnapshot] = await Promise.all([
		db.collection("adminRevenueTransactions").get(),
		db.collection("subscriptions").get(),
	]);
	let revenue = 0;
	let skipped = 0;
	let subscriptions = 0;
	await forEachBounded(
		revenueSnapshot.docs,
		BACKFILL_CONCURRENCY,
		async (document) => {
			const data = document.data();
			if (
				!paidProvider(data.provider) ||
				data.validationStatus !== "verified" ||
				(data.kind !== "charge" && data.kind !== "refund")
			) {
				return;
			}
			const occurredAt = dateValue(data.occurredAt);
			const amountMicros = data.amountMicros;
			const currency =
				typeof data.currency === "string"
					? data.currency.trim().toUpperCase()
					: "";
			if (
				!occurredAt ||
				typeof amountMicros !== "number" ||
				!Number.isSafeInteger(amountMicros) ||
				amountMicros < 0 ||
				!/^[A-Z]{3}$/.test(currency)
			) {
				skipped += 1;
				return;
			}
			await recordBillingActivity({
				provider: data.provider,
				eventKey: `historical_revenue:${document.id}`,
				eventType: data.kind === "refund" ? "refund" : "charge",
				occurredAt,
				origin: "historical",
				userId: typeof data.userId === "string" ? data.userId : null,
				environment:
					typeof data.environment === "string" ? data.environment : "unknown",
				amountMicros,
				currency,
				revenueKind: data.kind === "refund" ? "refund" : "charge",
				revenueStatus: "recorded",
			});
			revenue += 1;
		},
	);
	await forEachBounded(
		subscriptionSnapshot.docs,
		BACKFILL_CONCURRENCY,
		async (document) => {
			const data = document.data();
			if (!paidProvider(data.source)) return;
			const occurredAt =
				dateValue(data.updatedAt) ??
				dateValue(data.startTime) ??
				dateValue(data.createdAt);
			if (!occurredAt) return;
			await recordBillingActivity({
				provider: data.source,
				eventKey: `historical_subscription:${document.id}`,
				eventType: historicalSubscriptionType(data),
				occurredAt,
				origin: "historical",
				userId: typeof data.userId === "string" ? data.userId : null,
				billingPeriod:
					typeof data.billingPeriod === "string" ? data.billingPeriod : null,
				productId: typeof data.productId === "string" ? data.productId : null,
				environment:
					typeof data.environment === "string" ? data.environment : "unknown",
				subscriptionState:
					typeof data.subscriptionState === "string"
						? data.subscriptionState
						: null,
				entitlementState:
					typeof data.entitlementState === "string"
						? data.entitlementState
						: null,
			});
			subscriptions += 1;
		},
	);
	return { revenue, skipped, subscriptions };
}
