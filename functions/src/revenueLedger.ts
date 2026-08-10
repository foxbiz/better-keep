import { FieldValue, Timestamp } from "firebase-admin/firestore";
import {
	ADMIN_METRICS_COLLECTION,
	ADMIN_REVENUE_COLLECTION,
	ADMIN_REVENUE_SUMMARY_COLLECTION,
} from "./adminConfig";
import { db } from "./config";

export type RevenueProvider = "app_store" | "play_store" | "razorpay";
export type RevenueKind = "charge" | "refund";

export interface RevenueTransactionInput {
	amountMicros: number;
	currency: string;
	environment: "production" | "sandbox" | "unknown";
	kind: RevenueKind;
	occurredAt: Date;
	provider: RevenueProvider;
	providerTransactionId: string;
	userId?: string | null;
	metadata?: Record<string, unknown>;
	validationStatus?: "excluded" | "verified";
}

export function monthKey(date: Date): string {
	return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

export function minorUnitsToMicros(amount: number, fractionDigits = 2): number {
	if (!Number.isSafeInteger(amount) || amount < 0) {
		throw new Error("Payment amount must be a non-negative safe integer");
	}
	const multiplier = 10 ** (6 - fractionDigits);
	const micros = amount * multiplier;
	if (!Number.isSafeInteger(micros)) {
		throw new Error("Payment amount exceeds supported precision");
	}
	return micros;
}

export function decimalToMicros(value: string | number): number {
	const normalized = String(value).replace(/,/g, "").trim();
	if (!/^\d+(\.\d{1,6})?$/.test(normalized)) {
		throw new Error(`Invalid decimal payment amount: ${value}`);
	}
	const [units, decimals = ""] = normalized.split(".");
	const micros = Number(units) * 1_000_000 + Number(decimals.padEnd(6, "0"));
	if (!Number.isSafeInteger(micros)) {
		throw new Error("Payment amount exceeds supported precision");
	}
	return micros;
}

export function revenueContributions(
	data: Record<string, unknown> | undefined,
): { gross: number; net: number; refunds: number } {
	if (
		data?.environment !== "production" ||
		data.validationStatus === "excluded"
	) {
		return { gross: 0, net: 0, refunds: 0 };
	}
	const amount = Number(data.amountMicros ?? 0);
	if (!Number.isSafeInteger(amount) || amount < 0) {
		return { gross: 0, net: 0, refunds: 0 };
	}
	if (data.kind === "charge") return { gross: amount, net: amount, refunds: 0 };
	if (data.kind === "refund") {
		return { gross: 0, net: -amount, refunds: amount };
	}
	return { gross: 0, net: 0, refunds: 0 };
}

function normalizedCurrency(value: string): string {
	const currency = value.trim().toUpperCase();
	if (!/^[A-Z]{3}$/.test(currency)) {
		throw new Error(`Invalid ISO currency: ${value}`);
	}
	return currency;
}

function summaryCurrencies(
	data: Record<string, unknown> | undefined,
): Record<string, number> {
	const currencies = data?.currencies;
	if (!currencies || typeof currencies !== "object") return {};
	return Object.fromEntries(
		Object.entries(currencies as Record<string, unknown>).map(
			([key, value]) => [key, Number(value) || 0],
		),
	);
}

export function revenueSummaryAmounts(
	data: Record<string, unknown> | undefined,
): {
	grossCurrencies: Record<string, number>;
	netCurrencies: Record<string, number>;
	refundCurrencies: Record<string, number>;
} {
	const grossCurrencies = summaryCurrencies({
		currencies: data?.grossCurrencies ?? data?.currencies,
	});
	const refundCurrencies = summaryCurrencies({
		currencies: data?.refundCurrencies,
	});
	const storedNet = summaryCurrencies({ currencies: data?.netCurrencies });
	const netCurrencies =
		Object.keys(storedNet).length > 0
			? storedNet
			: Object.fromEntries(
					[
						...new Set([
							...Object.keys(grossCurrencies),
							...Object.keys(refundCurrencies),
						]),
					].map((currency) => [
						currency,
						(grossCurrencies[currency] ?? 0) -
							(refundCurrencies[currency] ?? 0),
					]),
				);
	return { grossCurrencies, refundCurrencies, netCurrencies };
}

export async function recordRevenueTransaction(
	input: RevenueTransactionInput,
): Promise<void> {
	if (!input.providerTransactionId.trim()) {
		throw new Error("Provider transaction ID is required");
	}
	if (!Number.isSafeInteger(input.amountMicros) || input.amountMicros < 0) {
		throw new Error("Revenue amount must be a non-negative safe integer");
	}
	if (Number.isNaN(input.occurredAt.getTime())) {
		throw new Error("Revenue occurrence date is invalid");
	}

	const currency = normalizedCurrency(input.currency);
	const transactionId = `${input.provider}_${input.providerTransactionId}`;
	const transactionRef = db
		.collection(ADMIN_REVENUE_COLLECTION)
		.doc(transactionId);
	const lifetimeRef = db
		.collection(ADMIN_REVENUE_SUMMARY_COLLECTION)
		.doc("lifetime");
	const nextMonthKey = monthKey(input.occurredAt);
	const nextMonthRef = db
		.collection(ADMIN_REVENUE_SUMMARY_COLLECTION)
		.doc(`month_${nextMonthKey}`);
	const metricsRef = db.collection(ADMIN_METRICS_COLLECTION).doc("current");

	await db.runTransaction(async (transaction) => {
		const existing = await transaction.get(transactionRef);
		if (existing.exists) return;

		const refs = [lifetimeRef, nextMonthRef, metricsRef];
		const summarySnaps = await transaction.getAll(...refs);
		const summaries = new Map(
			summarySnaps.map((snapshot) => [snapshot.ref.path, snapshot.data()]),
		);

		const nextData: Record<string, unknown> = {
			provider: input.provider,
			providerTransactionId: input.providerTransactionId,
			userId: input.userId ?? null,
			amountMicros: input.amountMicros,
			currency,
			kind: input.kind,
			environment: input.environment,
			occurredAt: Timestamp.fromDate(input.occurredAt),
			monthKey: nextMonthKey,
			metadata: input.metadata ?? {},
			validationStatus: input.validationStatus ?? "verified",
			createdAt: FieldValue.serverTimestamp(),
		};
		const nextContribution = revenueContributions(nextData);

		const applyDelta = (
			ref: FirebaseFirestore.DocumentReference,
			field: "grossCurrencies" | "netCurrencies" | "refundCurrencies",
			deltaCurrency: string,
			delta: number,
		): void => {
			if (delta === 0) return;
			const existingSummary = summaries.get(ref.path);
			const amounts = revenueSummaryAmounts(existingSummary);
			const currencies = { ...amounts[field] };
			currencies[deltaCurrency] = (currencies[deltaCurrency] ?? 0) + delta;
			if (currencies[deltaCurrency] === 0) delete currencies[deltaCurrency];
			const update: Record<string, unknown> = {
				[field]: currencies,
				updatedAt: FieldValue.serverTimestamp(),
			};
			if (field === "grossCurrencies") update.currencies = currencies;
			transaction.set(ref, update, { merge: true });
			summaries.set(ref.path, {
				...existingSummary,
				...update,
			});
		};

		for (const [field, delta] of [
			["grossCurrencies", nextContribution.gross],
			["refundCurrencies", nextContribution.refunds],
			["netCurrencies", nextContribution.net],
		] as const) {
			applyDelta(lifetimeRef, field, currency, delta);
			applyDelta(nextMonthRef, field, currency, delta);
		}

		const metricsData = summaries.get(metricsRef.path);
		const existingCoverage =
			metricsData?.revenueCoverage &&
			typeof metricsData.revenueCoverage === "object"
				? (metricsData.revenueCoverage as Record<
						string,
						Record<string, unknown>
					>)
				: {};
		const providerCoverage = existingCoverage[input.provider] ?? {};
		const existingStartedAt = providerCoverage.startedAt;
		const existingLastRecordedAt = providerCoverage.lastRecordedAt;
		const startedAt =
			existingStartedAt instanceof Timestamp &&
			existingStartedAt.toMillis() <= input.occurredAt.getTime()
				? existingStartedAt
				: Timestamp.fromDate(input.occurredAt);
		const lastRecordedAt =
			existingLastRecordedAt instanceof Timestamp &&
			existingLastRecordedAt.toMillis() >= input.occurredAt.getTime()
				? existingLastRecordedAt
				: Timestamp.fromDate(input.occurredAt);
		if (
			input.environment === "production" &&
			input.validationStatus !== "excluded"
		) {
			transaction.set(
				metricsRef,
				{
					revenueCoverage: {
						...existingCoverage,
						[input.provider]: {
							...providerCoverage,
							startedAt,
							lastRecordedAt,
						},
					},
					revenueUpdatedAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);
		}
		transaction.create(transactionRef, nextData);
	});
}
