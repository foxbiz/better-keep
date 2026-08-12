import { FieldValue, Timestamp } from "firebase-admin/firestore";
import {
	ADMIN_METRICS_COLLECTION,
	ADMIN_REVENUE_COLLECTION,
	ADMIN_REVENUE_SUMMARY_COLLECTION,
} from "./adminConfig";
import { db } from "./config";
import { monthKey, revenueContributions } from "./revenueLedger";

type CurrencyTotals = Record<string, number>;
export interface RebuiltRevenueSummary {
	coverage: Record<string, { lastRecordedAt: Timestamp; startedAt: Timestamp }>;
	lifetime: RevenueTotals;
	months: Record<string, RevenueTotals>;
}
export interface RevenueTotals {
	grossCurrencies: CurrencyTotals;
	netCurrencies: CurrencyTotals;
	refundCurrencies: CurrencyTotals;
}

function emptyTotals(): RevenueTotals {
	return { grossCurrencies: {}, netCurrencies: {}, refundCurrencies: {} };
}

function add(target: CurrencyTotals, currency: string, amount: number): void {
	if (amount === 0) return;
	target[currency] = (target[currency] ?? 0) + amount;
	if (target[currency] === 0) delete target[currency];
}

export function aggregateRevenueTransactions(
	documents: Array<Record<string, unknown>>,
): RebuiltRevenueSummary {
	const result: RebuiltRevenueSummary = {
		coverage: {},
		lifetime: emptyTotals(),
		months: {},
	};
	for (const data of documents) {
		const occurredAt = data.occurredAt;
		const currency =
			typeof data.currency === "string" ? data.currency.toUpperCase() : null;
		const provider = typeof data.provider === "string" ? data.provider : null;
		if (!(occurredAt instanceof Timestamp) || !currency || !provider) continue;
		const contribution = revenueContributions(data);
		if (
			contribution.gross === 0 &&
			contribution.refunds === 0 &&
			contribution.net === 0
		) {
			continue;
		}
		const month = monthKey(occurredAt.toDate());
		const monthly = (result.months[month] ??= emptyTotals());
		for (const totals of [result.lifetime, monthly]) {
			add(totals.grossCurrencies, currency, contribution.gross);
			add(totals.refundCurrencies, currency, contribution.refunds);
			add(totals.netCurrencies, currency, contribution.net);
		}
		const coverage = result.coverage[provider];
		if (!coverage) {
			result.coverage[provider] = {
				lastRecordedAt: occurredAt,
				startedAt: occurredAt,
			};
		} else {
			if (occurredAt.toMillis() < coverage.startedAt.toMillis()) {
				coverage.startedAt = occurredAt;
			}
			if (occurredAt.toMillis() > coverage.lastRecordedAt.toMillis()) {
				coverage.lastRecordedAt = occurredAt;
			}
		}
	}
	return result;
}

function summaryDocument(totals: RevenueTotals): Record<string, unknown> {
	return {
		...totals,
		currencies: totals.grossCurrencies,
		updatedAt: FieldValue.serverTimestamp(),
	};
}

export async function rebuildRevenueSummaries(): Promise<RebuiltRevenueSummary> {
	const [transactions, existingSummaries] = await Promise.all([
		db.collection(ADMIN_REVENUE_COLLECTION).get(),
		db.collection(ADMIN_REVENUE_SUMMARY_COLLECTION).get(),
	]);
	const rebuilt = aggregateRevenueTransactions(
		transactions.docs.map((document) => document.data()),
	);
	const writes: Array<Promise<unknown>> = [
		db
			.collection(ADMIN_REVENUE_SUMMARY_COLLECTION)
			.doc("lifetime")
			.set(summaryDocument(rebuilt.lifetime), { merge: false }),
	];
	const monthIds = new Set([
		...Object.keys(rebuilt.months).map((month) => `month_${month}`),
		...existingSummaries.docs
			.map((document) => document.id)
			.filter((id) => id.startsWith("month_")),
	]);
	for (const id of monthIds) {
		const month = id.slice("month_".length);
		writes.push(
			db
				.collection(ADMIN_REVENUE_SUMMARY_COLLECTION)
				.doc(id)
				.set(summaryDocument(rebuilt.months[month] ?? emptyTotals()), {
					merge: false,
				}),
		);
	}
	await Promise.all(writes);
	await db.collection(ADMIN_METRICS_COLLECTION).doc("current").set(
		{
			revenueCoverage: rebuilt.coverage,
			revenueUpdatedAt: FieldValue.serverTimestamp(),
		},
		{ merge: true },
	);
	return rebuilt;
}
