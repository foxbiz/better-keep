import { createHash } from "node:crypto";
import { FieldValue, type Timestamp } from "firebase-admin/firestore";
import {
	ADMIN_SUBSCRIPTION_ISSUE_COLLECTION,
	PAID_SUBSCRIPTION_SOURCES,
} from "./adminConfig";
import type { SubscriptionClaimsAuth } from "./adminIdentityToolkitUsers";
import { auth, db } from "./config";
import { mergeSubscriptionClaims } from "./customClaims";
import {
	type EvaluatedSubscription,
	type RenewalState,
	evaluateSubscription,
	isPaidSubscriptionSource,
} from "./subscriptionEntitlement";

interface Candidate {
	data: Record<string, unknown>;
	evaluated: EvaluatedSubscription;
	recordId: string;
}

export interface ReconciledEntitlement {
	activeSources: string[];
	entitlementState: string | null;
	expiresAt: Timestamp | null;
	plan: "free" | "pro";
	primarySource: string | null;
	providerState: string | null;
	renewalState: RenewalState;
	resolution: "active_provider" | "none" | "provider_inactive" | "trial";
}

function issueId(kind: string, value: string): string {
	return `${kind}_${createHash("sha256").update(value).digest("hex").slice(0, 32)}`;
}

function isPaidSource(value: unknown): boolean {
	return (
		typeof value === "string" &&
		(PAID_SUBSCRIPTION_SOURCES as readonly string[]).includes(value)
	);
}

function providerCandidate(
	recordId: string,
	data: Record<string, unknown>,
	now: number,
): Candidate {
	const withPlan = isPaidSource(data.source)
		? { ...data, plan: data.plan ?? "pro" }
		: data;
	return {
		data: withPlan,
		evaluated: evaluateSubscription(withPlan, now),
		recordId,
	};
}

function compareCandidates(a: Candidate, b: Candidate): number {
	const expiryDifference =
		(b.evaluated.expiresAt?.toMillis() ?? 0) -
		(a.evaluated.expiresAt?.toMillis() ?? 0);
	if (expiryDifference !== 0) return expiryDifference;
	const sourceDifference = (a.evaluated.source ?? "").localeCompare(
		b.evaluated.source ?? "",
	);
	if (sourceDifference !== 0) return sourceDifference;
	return a.recordId.localeCompare(b.recordId);
}

export function canonicalStatusCleanupFieldNames(
	source: string | null,
): string[] {
	return [
		"purchasePlatform",
		"expiryDate",
		"status",
		"autoRenew",
		...(source === "trial" ? [] : ["trialStartedAt", "trialExpiresAt"]),
	];
}

export function selectEffectiveEntitlements({
	current,
	providerRecords,
	now = Date.now(),
}: {
	current?: Record<string, unknown> | null;
	providerRecords: Array<{ id: string; data: Record<string, unknown> }>;
	now?: number;
}): {
	active: Candidate[];
	inactiveProvider: Candidate | null;
	primary: Candidate | null;
} {
	const providerCandidates = providerRecords.map(({ id, data }) =>
		providerCandidate(id, data, now),
	);
	const activeProviders = providerCandidates
		.filter(
			(candidate) =>
				candidate.evaluated.entitled &&
				isPaidSubscriptionSource(candidate.evaluated.source),
		)
		.sort(compareCandidates);
	const currentSource = evaluateSubscription(current, now).source;

	// A verified provider always replaces non-provider access such as a trial.
	// This also keeps a longer trial expiry from extending a paid subscription.
	if (activeProviders.length > 0) {
		const preservedProvider =
			currentSource && isPaidSubscriptionSource(currentSource)
				? activeProviders.find(
						(candidate) => candidate.evaluated.source === currentSource,
					)
				: null;
		return {
			active: activeProviders,
			inactiveProvider: null,
			primary: preservedProvider ?? activeProviders[0],
		};
	}

	const inactiveProviders = providerCandidates
		.filter((candidate) => isPaidSubscriptionSource(candidate.evaluated.source))
		.sort(compareCandidates);
	if (inactiveProviders.length > 0) {
		// A verified paid conversion permanently consumes the trial. Once any
		// provider history exists, an older trial document must never resume.
		return {
			active: [],
			inactiveProvider: inactiveProviders[0],
			primary: null,
		};
	}

	// Retain the canonical status only as a legacy/non-provider fallback when
	// there is no active verified provider. Once a trial converts, it is removed
	// from the canonical status and therefore cannot resume later.
	const currentEvaluation = evaluateSubscription(current, now);
	if (!current || !currentEvaluation.entitled) {
		const inactiveCurrent =
			current && isPaidSubscriptionSource(currentEvaluation.source)
				? {
						data: current,
						evaluated: currentEvaluation,
						recordId: "legacy_status",
					}
				: null;
		return {
			active: [],
			inactiveProvider: inactiveCurrent,
			primary: null,
		};
	}
	const legacy = {
		data: current,
		evaluated: currentEvaluation,
		recordId: "legacy_status",
	};
	return { active: [legacy], inactiveProvider: null, primary: legacy };
}

async function updateClaims(
	userId: string,
	plan: "free" | "pro",
	expiresAt: Timestamp | null,
	claimsAuth: SubscriptionClaimsAuth,
): Promise<void> {
	const user = await claimsAuth.getUser(userId);
	await claimsAuth.setCustomUserClaims(
		userId,
		mergeSubscriptionClaims(
			user.customClaims,
			plan,
			expiresAt ? expiresAt.toDate() : null,
		),
	);
}

export async function reconcileUserEntitlement(
	userId: string,
	now = Date.now(),
	claimsAuth: SubscriptionClaimsAuth = auth,
): Promise<ReconciledEntitlement> {
	const userRef = db.collection("users").doc(userId);
	const statusRef = userRef.collection("subscription").doc("status");
	const [currentSnapshot, providerSnapshot] = await Promise.all([
		statusRef.get(),
		db.collection("subscriptions").where("userId", "==", userId).get(),
	]);
	const current = currentSnapshot.data();
	const { active, inactiveProvider, primary } = selectEffectiveEntitlements({
		current,
		providerRecords: providerSnapshot.docs.map((document) => ({
			id: document.id,
			data: document.data(),
		})),
		now,
	});
	const maximumExpiry = active.reduce<Timestamp | null>((latest, candidate) => {
		const expiry = candidate.evaluated.expiresAt;
		if (!expiry) return latest;
		return !latest || expiry.toMillis() > latest.toMillis() ? expiry : latest;
	}, null);
	const activeSources = [
		...new Set(
			active
				.map((candidate) => candidate.evaluated.source)
				.filter((source): source is string => source !== null),
		),
	].sort();
	const productionPaid = active.filter(
		(candidate) => candidate.evaluated.productionPaid,
	);
	const paidCandidates = productionPaid;

	if (!primary || !maximumExpiry) {
		await statusRef.delete();
	} else {
		await statusRef.set(
			{
				plan: "pro",
				source: primary.evaluated.source,
				// Canonical fields above replace all legacy aliases. In particular,
				// a stale purchasePlatform/expiryDate from a trial must not override
				// the newly verified provider on older clients.
				...Object.fromEntries(
					canonicalStatusCleanupFieldNames(primary.evaluated.source).map(
						(field) => [field, FieldValue.delete()],
					),
				),
				environment: primary.evaluated.environment,
				billingPeriod: primary.evaluated.billingPeriod,
				expiresAt: maximumExpiry,
				renewalState: primary.evaluated.renewalState,
				willAutoRenew:
					primary.evaluated.renewalState === "unknown"
						? null
						: primary.evaluated.renews,
				subscriptionState: primary.evaluated.state,
				entitlementState: primary.evaluated.entitlementState,
				productId: primary.data.productId ?? FieldValue.delete(),
				purchaseToken: primary.data.purchaseToken ?? FieldValue.delete(),
				providerSubscriptionId:
					primary.data.providerSubscriptionId ?? FieldValue.delete(),
				razorpaySubscriptionId:
					primary.evaluated.source === "razorpay"
						? (primary.data.providerSubscriptionId ??
							primary.data.razorpaySubscriptionId ??
							FieldValue.delete())
						: FieldValue.delete(),
				...(primary.evaluated.source === "trial"
					? {
							trialStartedAt:
								primary.data.trialStartedAt ?? FieldValue.delete(),
							trialExpiresAt:
								primary.data.trialExpiresAt ?? FieldValue.delete(),
						}
					: {}),
				activeSources,
				activeSubscriptionCount: active.length,
				hasProductionPaidEntitlement: productionPaid.length > 0,
				hasRenewingPaidEntitlement: paidCandidates.some(
					(candidate) => candidate.evaluated.renews,
				),
				reconciledAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);
	}

	const claimsIssueRef = db
		.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
		.doc(issueId("claims", userId));
	try {
		await updateClaims(
			userId,
			primary ? "pro" : "free",
			maximumExpiry,
			claimsAuth,
		);
		await claimsIssueRef.delete();
	} catch (error) {
		await claimsIssueRef.set(
			{
				type: "claims_sync_failed",
				status: "open",
				userId,
				errorCode:
					typeof (error as { code?: unknown }).code === "string"
						? (error as { code: string }).code.slice(0, 120)
						: error instanceof Error
							? error.name.slice(0, 120)
							: "unknown",
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);
		throw error;
	}

	return {
		activeSources,
		entitlementState:
			primary?.evaluated.entitlementState ??
			inactiveProvider?.evaluated.entitlementState ??
			null,
		expiresAt: maximumExpiry ?? inactiveProvider?.evaluated.expiresAt ?? null,
		plan: primary ? "pro" : "free",
		primarySource:
			primary?.evaluated.source ?? inactiveProvider?.evaluated.source ?? null,
		providerState:
			primary?.evaluated.state ?? inactiveProvider?.evaluated.state ?? null,
		renewalState:
			primary?.evaluated.renewalState ??
			inactiveProvider?.evaluated.renewalState ??
			"unknown",
		resolution: primary
			? isPaidSubscriptionSource(primary.evaluated.source)
				? "active_provider"
				: "trial"
			: inactiveProvider
				? "provider_inactive"
				: "none",
	};
}
