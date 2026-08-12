import { createHash } from "node:crypto";
import {
	evaluateSubscription,
	type EntitlementState,
	type SubscriptionEnvironment,
} from "./subscriptionEntitlement";

export type GooglePlayReconciliationClassification =
	| "cancelled_access"
	| "expired_or_revoked"
	| "grace"
	| "linked_entitled"
	| "linked_renewing"
	| "overlap"
	| "pending"
	| "recoverable"
	| "suspended"
	| "test"
	| "unmatched"
	| "verification_failed";

export type GooglePlayAccountMatch =
	| "absent"
	| "exact"
	| "legacy"
	| "mismatch"
	| "unknown"
	| "user_missing";

export type GooglePlayFirebaseLookup =
	| "failed"
	| "not_applicable"
	| "not_found"
	| "verified";

export interface GooglePlayReconciliationRow {
	accessAligned: boolean;
	accountMatch: GooglePlayAccountMatch;
	classification: GooglePlayReconciliationClassification;
	entitlementState: EntitlementState;
	environment: SubscriptionEnvironment;
	expiresAt: string | null;
	firebaseEntitled: boolean;
	firebaseLookup: GooglePlayFirebaseLookup;
	firebaseUserId: string | null;
	googleEntitled: boolean;
	googleState: string | null;
	providerRef: string;
	storedUserId: string | null;
	verification: "gone" | "verified" | "failed";
	verificationErrorCode: string | number | null;
	willAutoRenew: boolean;
}

function nonEmptyText(value: unknown): string | null {
	return typeof value === "string" && value.trim().length > 0
		? value.trim()
		: null;
}

export function googlePlayProviderRef(providerKey: string): string {
	return `play:${createHash("sha256")
		.update(providerKey)
		.digest("hex")
		.slice(0, 12)}`;
}

export function candidateGooglePlayUserId({
	externalAccountId,
	storedUserId,
}: {
	externalAccountId: string | null;
	storedUserId: string | null;
}): string | null {
	if (externalAccountId && storedUserId && externalAccountId !== storedUserId) {
		return null;
	}
	return externalAccountId ?? storedUserId;
}

function accountMatch({
	externalAccountId,
	linkedUserId,
	storedUserId,
	verification,
	firebaseLookup,
}: {
	externalAccountId: string | null;
	linkedUserId: string | null;
	storedUserId: string | null;
	verification: GooglePlayReconciliationRow["verification"];
	firebaseLookup: GooglePlayFirebaseLookup;
}): GooglePlayAccountMatch {
	if (verification !== "verified") return "unknown";
	if (externalAccountId && storedUserId && externalAccountId !== storedUserId) {
		return "mismatch";
	}
	if (firebaseLookup === "failed") return "unknown";
	if (externalAccountId) {
		return linkedUserId === externalAccountId ? "exact" : "user_missing";
	}
	if (storedUserId) {
		return linkedUserId === storedUserId ? "legacy" : "user_missing";
	}
	return "absent";
}

function baseClassification({
	accountStatus,
	evaluation,
	linkedUserId,
	storedUserId,
	verification,
}: {
	accountStatus: GooglePlayAccountMatch;
	evaluation: ReturnType<typeof evaluateSubscription>;
	linkedUserId: string | null;
	storedUserId: string | null;
	verification: GooglePlayReconciliationRow["verification"];
}): GooglePlayReconciliationClassification {
	if (verification === "failed") return "verification_failed";
	if (verification === "gone" && !evaluation.entitled) {
		return "expired_or_revoked";
	}
	if (evaluation.environment === "test") return "test";
	if (!linkedUserId || accountStatus === "mismatch") return "unmatched";
	if (!evaluation.entitled) {
		if (evaluation.entitlementState === "suspended") return "suspended";
		if (evaluation.entitlementState === "pending") return "pending";
		return "expired_or_revoked";
	}
	if (!storedUserId && accountStatus === "exact") return "recoverable";
	if (evaluation.entitlementState === "cancelled_access") {
		return "cancelled_access";
	}
	if (evaluation.entitlementState === "grace") return "grace";
	return evaluation.renews ? "linked_renewing" : "linked_entitled";
}

export function buildGooglePlayReconciliationRow({
	externalAccountId = null,
	firebaseStatus,
	linkedUserId = null,
	normalizedSubscription,
	providerKey,
	storedUserId = null,
	verification = "verified",
	verificationErrorCode = null,
	firebaseLookup,
}: {
	externalAccountId?: string | null;
	firebaseStatus?: Record<string, unknown> | null;
	linkedUserId?: string | null;
	normalizedSubscription: Record<string, unknown>;
	providerKey: string;
	storedUserId?: string | null;
	verification?: GooglePlayReconciliationRow["verification"];
	verificationErrorCode?: string | number | null;
	firebaseLookup?: GooglePlayFirebaseLookup;
}): GooglePlayReconciliationRow {
	const evaluation = evaluateSubscription(normalizedSubscription);
	const firebaseEvaluation = evaluateSubscription(firebaseStatus);
	const firebaseUserId = nonEmptyText(linkedUserId);
	const resolvedFirebaseLookup =
		firebaseLookup ?? (firebaseUserId ? "verified" : "not_applicable");
	const resolvedAccountMatch = accountMatch({
		externalAccountId: nonEmptyText(externalAccountId),
		linkedUserId: firebaseUserId,
		storedUserId: nonEmptyText(storedUserId),
		verification,
		firebaseLookup: resolvedFirebaseLookup,
	});
	const expectsPaidAccess = evaluation.productionPaid;
	return {
		accessAligned:
			!expectsPaidAccess ||
			(firebaseUserId !== null && firebaseEvaluation.entitled),
		accountMatch: resolvedAccountMatch,
		classification: baseClassification({
			accountStatus: resolvedAccountMatch,
			evaluation,
			linkedUserId: firebaseUserId,
			storedUserId: nonEmptyText(storedUserId),
			verification,
		}),
		entitlementState: evaluation.entitlementState,
		environment: evaluation.environment,
		expiresAt: evaluation.expiresAt?.toDate().toISOString() ?? null,
		firebaseEntitled: firebaseEvaluation.entitled,
		firebaseLookup: resolvedFirebaseLookup,
		firebaseUserId,
		googleEntitled: evaluation.entitled,
		googleState: evaluation.state,
		providerRef: googlePlayProviderRef(providerKey),
		storedUserId: nonEmptyText(storedUserId),
		verification,
		verificationErrorCode,
		willAutoRenew: evaluation.renews,
	};
}

export function markGooglePlayOverlaps(
	rows: GooglePlayReconciliationRow[],
): GooglePlayReconciliationRow[] {
	const grouped = new Map<string, GooglePlayReconciliationRow[]>();
	for (const row of rows) {
		if (
			!row.firebaseUserId ||
			!row.googleEntitled ||
			row.environment !== "production"
		) {
			continue;
		}
		const group = grouped.get(row.firebaseUserId) ?? [];
		group.push(row);
		grouped.set(row.firebaseUserId, group);
	}
	const overlappingRefs = new Set<string>();
	for (const group of grouped.values()) {
		if (group.length < 2) continue;
		const sorted = [...group].sort((a, b) => {
			const expiryDifference =
				Date.parse(b.expiresAt ?? "1970-01-01T00:00:00.000Z") -
				Date.parse(a.expiresAt ?? "1970-01-01T00:00:00.000Z");
			return expiryDifference || a.providerRef.localeCompare(b.providerRef);
		});
		for (const secondary of sorted.slice(1)) {
			overlappingRefs.add(secondary.providerRef);
		}
	}
	return rows
		.map((row) =>
			overlappingRefs.has(row.providerRef)
				? { ...row, classification: "overlap" as const }
				: row,
		)
		.sort((a, b) => a.providerRef.localeCompare(b.providerRef));
}

export function formatGooglePlayReconciliationReport(
	rows: GooglePlayReconciliationRow[],
): string {
	return JSON.stringify(
		rows.map((row) => ({
			providerRef: row.providerRef,
			storedUserId: row.storedUserId,
			firebaseUserId: row.firebaseUserId,
			classification: row.classification,
			googleState: row.googleState,
			willAutoRenew: row.willAutoRenew,
			expiresAt: row.expiresAt,
			environment: row.environment,
			accountMatch: row.accountMatch,
			googleEntitled: row.googleEntitled,
			firebaseEntitled: row.firebaseEntitled,
			firebaseLookup: row.firebaseLookup,
			accessAligned: row.accessAligned,
			verification: row.verification,
			verificationErrorCode: row.verificationErrorCode,
		})),
		null,
		2,
	);
}
