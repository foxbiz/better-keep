import { createHash } from "node:crypto";
import { evaluateSubscription } from "./subscriptionEntitlement";

export type BillingProvider = "all" | "play" | "razorpay";
export type ProviderFailureClass = "configuration" | "retryable" | "unresolved";

export interface SanitizedProviderFailure {
	blocking: boolean;
	failureClass: ProviderFailureClass;
	status: number | null;
}

export interface StoredProviderCounts {
	effectiveEntitled: number;
	known: number;
	productionPaid: number;
}

export interface StoredOnlySubscriptionRow {
	effectiveEntitlement: boolean;
	environment: string;
	expiresAt: string | null;
	firebaseUserId: string | null;
	intendedAction: "preserve_stored_only";
	productionPaid: boolean;
	providerRef: string;
	providerState: string | null;
}

export function providerReference(source: string, providerKey: string): string {
	return `${source}:${createHash("sha256")
		.update(providerKey)
		.digest("hex")
		.slice(0, 12)}`;
}

export function sanitizedErrorCode(error: unknown): string {
	const code = (error as { code?: unknown })?.code;
	if (typeof code === "string" && code.length > 0) return code.slice(0, 120);
	if (error instanceof Error && error.name.length > 0) {
		return error.name.slice(0, 120);
	}
	return "unknown";
}

export function classifyRazorpayProviderFailure(
	error: unknown,
): SanitizedProviderFailure {
	const status =
		typeof (error as { status?: unknown })?.status === "number"
			? (error as { status: number }).status
			: null;
	if (status === 400 || status === 404) {
		return { blocking: false, failureClass: "unresolved", status };
	}
	if (status === 401 || status === 403) {
		return { blocking: true, failureClass: "configuration", status };
	}
	return { blocking: true, failureClass: "retryable", status };
}

export function isAuthoritativelySelectedSource(
	provider: BillingProvider,
	source: string,
): boolean {
	return (
		(provider !== "razorpay" && source === "play_store") ||
		(provider !== "play" && source === "razorpay")
	);
}

export function storedProviderCounts(
	records: ReadonlyArray<Record<string, unknown>>,
): Record<string, StoredProviderCounts> {
	const result: Record<string, StoredProviderCounts> = {};
	for (const data of records) {
		const source = typeof data.source === "string" ? data.source : "unknown";
		if (!result[source]) {
			result[source] = {
				effectiveEntitled: 0,
				known: 0,
				productionPaid: 0,
			};
		}
		const counts = result[source];
		const evaluated = evaluateSubscription(data);
		counts.known += 1;
		if (evaluated.entitled) counts.effectiveEntitled += 1;
		if (evaluated.productionPaid) counts.productionPaid += 1;
	}
	return result;
}

export function storedOnlySubscriptionRow({
	data,
	providerKey,
}: {
	data: Record<string, unknown>;
	providerKey: string;
}): StoredOnlySubscriptionRow {
	const evaluated = evaluateSubscription(data);
	return {
		effectiveEntitlement: evaluated.entitled,
		environment: evaluated.environment,
		expiresAt: evaluated.expiresAt?.toDate().toISOString() ?? null,
		firebaseUserId: typeof data.userId === "string" ? data.userId : null,
		intendedAction: "preserve_stored_only",
		productionPaid: evaluated.productionPaid,
		providerRef: providerReference("app_store", providerKey),
		providerState: evaluated.state,
	};
}

export function verifiedReconciliationUserIds(
	actions: ReadonlyArray<{ kind: string; userId: string }>,
): string[] {
	return [
		...new Set(
			actions
				.filter((action) => action.kind === "persist")
				.map((action) => action.userId),
		),
	].sort();
}

export function assertNoBlockingProviderFailures(
	failures: readonly SanitizedProviderFailure[],
): void {
	const blocking = failures.filter((failure) => failure.blocking);
	if (blocking.length === 0) return;
	const classes = [...new Set(blocking.map((failure) => failure.failureClass))]
		.sort()
		.join(", ");
	throw new Error(
		`Provider preflight blocked execution (${blocking.length}: ${classes})`,
	);
}

export async function applyAfterProviderPreflight<T>(
	failures: readonly SanitizedProviderFailure[],
	apply: () => Promise<T>,
): Promise<T> {
	assertNoBlockingProviderFailures(failures);
	return apply();
}
