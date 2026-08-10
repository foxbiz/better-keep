/**
 * Audits provider subscriptions and revenue. Dry-run is the default; execute
 * requires an explicit production target and interactive confirmation.
 */
import * as readline from "node:readline/promises";
import { applicationDefault } from "firebase-admin/app";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import {
	ADMIN_METRICS_COLLECTION,
	ADMIN_REVENUE_COLLECTION,
	ADMIN_SUBSCRIPTION_ISSUE_COLLECTION,
} from "../src/adminConfig";
import {
	identityToolkitClaimsAuth,
	identityToolkitUserExists,
	listIdentityToolkitUsers,
	type SubscriptionClaimsAuth,
} from "../src/adminIdentityToolkitUsers";
import {
	applyAfterProviderPreflight,
	assertNoBlockingProviderFailures,
	type BillingProvider,
	classifyRazorpayProviderFailure,
	isAuthoritativelySelectedSource,
	providerReference,
	sanitizedErrorCode,
	storedOnlySubscriptionRow,
	storedProviderCounts,
	type SanitizedProviderFailure,
	verifiedReconciliationUserIds,
} from "../src/billingReconciliation";
import {
	app,
	databaseId,
	db,
	razorpayKeyId,
	razorpayKeySecret,
} from "../src/config";
import {
	buildGooglePlayReconciliationRow,
	candidateGooglePlayUserId,
	formatGooglePlayReconciliationReport,
	markGooglePlayOverlaps,
	type GooglePlayFirebaseLookup,
	type GooglePlayReconciliationRow,
} from "../src/googlePlayReconciliation";
import {
	getGooglePlaySubscription,
	persistVerifiedGooglePlaySubscription,
} from "../src/googlePlayService";
import {
	googlePlayAccountId,
	normalizeGooglePlaySubscription,
} from "../src/googlePlaySubscription";
import {
	getGooglePlayOrder,
	enqueueVerifiedGooglePlayOrder,
	type GooglePlayOrder,
	isGooglePlaySubscriptionSalesRow,
	listGooglePlaySalesReports,
	normalizeGooglePlayReportBucket,
	readGooglePlaySalesReport,
} from "../src/googlePlayRevenue";
import { enqueueRevenueEvent, processRevenueEvent } from "../src/revenueOutbox";
import { persistVerifiedRazorpaySubscriptionRecord } from "../src/razorpayService";
import {
	isVerifiedRazorpayPayment,
	normalizeRazorpaySubscription,
	type RazorpaySubscriptionEntity,
} from "../src/razorpaySubscription";
import {
	aggregateRevenueTransactions,
	rebuildRevenueSummaries,
} from "../src/revenueReconciler";
import { minorUnitsToMicros, revenueSummaryAmounts } from "../src/revenueLedger";
import { reconcileUserEntitlement } from "../src/subscriptionReconciler";
import { evaluateSubscription } from "../src/subscriptionEntitlement";
import {
	recordSubscriptionIssue,
	resolveSubscriptionIssues,
	resolveUserSubscriptionIssues,
} from "../src/subscriptionIssues";
import { providerSubscriptionCounts } from "../src/subscriptionMetrics";
import { razorpayRequest } from "../src/utils";
import { forEachBounded } from "../src/boundedConcurrency";

const EXPECTED_PROJECT = "better-keep-notes";
const EXPECTED_DATABASE = "better-keep";

function argument(name: string): string | null {
	const prefix = `--${name}=`;
	return process.argv.find((value) => value.startsWith(prefix))?.slice(prefix.length) ?? null;
}

function selectedBillingProvider(): BillingProvider {
	const provider = argument("provider") ?? "all";
	if (provider !== "all" && provider !== "play" && provider !== "razorpay") {
		throw new Error("--provider must be all, play, or razorpay");
	}
	return provider;
}

async function verifyFirebaseAuthPreflight({
	credential,
	projectId,
}: {
	credential: NonNullable<typeof app.options.credential>;
	projectId: string;
}): Promise<void> {
	try {
		await listIdentityToolkitUsers({ credential, projectId });
	} catch (error: unknown) {
		throw new Error(
			`Firebase Auth preflight failed (${sanitizedErrorCode(error)})`,
		);
	}
}

async function confirmTarget(): Promise<void> {
	if (!process.stdin.isTTY) throw new Error("Execution requires an interactive terminal");
	const prompt = readline.createInterface({ input: process.stdin, output: process.stdout });
	try {
		const expected = `${EXPECTED_PROJECT}/${EXPECTED_DATABASE}/RECONCILE-BILLING`;
		const answer = await prompt.question(`Type ${expected} to apply provider repairs: `);
		if (answer.trim() !== expected) throw new Error("Target confirmation did not match");
	} finally {
		prompt.close();
	}
}

type RazorpayPayment = {
	amount?: number;
	captured?: boolean;
	created_at?: number;
	currency?: string;
	id?: string;
	status?: string;
};
type RazorpayRefund = {
	amount?: number;
	created_at?: number;
	currency?: string;
	id?: string;
	status?: string;
};

type VerifiedRazorpayRefund = Required<
	Pick<RazorpayRefund, "amount" | "created_at" | "currency" | "id" | "status">
>;

interface RazorpaySubscriptionAuditRow {
	effectiveEntitlement: boolean;
	failureClass: string | null;
	firebaseUserExists: boolean | null;
	firebaseUserId: string;
	httpStatus: number | null;
	intendedAction:
		| "create_missing_user_issue"
		| "create_review_issue"
		| "normalize_and_reconcile"
		| "stop_before_writes";
	providerRef: string;
	providerState: string | null;
}

interface RazorpayPaymentAuditRow {
	failureClass: string | null;
	httpStatus: number | null;
	intendedAction: "quarantine" | "stop_before_writes" | "verify";
	providerRef: string;
}

type RazorpaySubscriptionAction =
	| {
			billingPeriod: string | null;
			entity: RazorpaySubscriptionEntity;
			kind: "persist";
			subscriptionId: string;
			userId: string;
	  }
	| {
			kind: "missing_user";
			subscriptionId: string;
			userId: string;
	  }
	| {
			failure: SanitizedProviderFailure;
			kind: "issue";
			subscriptionId: string;
			userId: string;
	  };

type RazorpayPaymentAction =
	| {
			data: FirebaseFirestore.DocumentData;
			document: FirebaseFirestore.QueryDocumentSnapshot;
			kind: "exclude";
			reason: string;
	  }
	| {
			data: FirebaseFirestore.DocumentData;
			document: FirebaseFirestore.QueryDocumentSnapshot;
			kind: "verify";
			payment: Required<
				Pick<
					RazorpayPayment,
					"amount" | "captured" | "created_at" | "currency" | "id" | "status"
				>
			>;
			refunds: VerifiedRazorpayRefund[];
	  };

interface RazorpayAudit {
	blockingFailures: SanitizedProviderFailure[];
	excluded: number;
	current: ReturnType<typeof aggregateRevenueTransactions>["lifetime"];
	paymentActions: RazorpayPaymentAction[];
	payments: RazorpayPaymentAuditRow[];
	projected: ReturnType<typeof aggregateRevenueTransactions>["lifetime"];
	refunds: number;
	subscriptionActions: RazorpaySubscriptionAction[];
	subscriptionFailures: number;
	subscriptions: RazorpaySubscriptionAuditRow[];
	subscriptionsVerified: number;
	verified: number;
}

async function auditRazorpay({
	credential,
	projectId,
}: {
	credential: NonNullable<typeof app.options.credential>;
	projectId: string;
}): Promise<RazorpayAudit> {
	const keyId = razorpayKeyId.value();
	const keySecret = razorpayKeySecret.value();
	if (!keyId || !keySecret) throw new Error("Razorpay credentials are required");
	const allSnapshot = await db
		.collection(ADMIN_REVENUE_COLLECTION)
		.where("provider", "==", "razorpay")
		.get();
	const snapshot = allSnapshot.docs.filter(
		(document) => document.data().kind === "charge",
	);
	const projectedDocuments = new Map(
		allSnapshot.docs.map((document) => [document.id, document.data()]),
	);
	const providerDocumentIds = new Map(
		allSnapshot.docs.map((document) => [
			String(document.data().providerTransactionId ?? ""),
			document.id,
		]),
	);
	let excluded = 0;
	let refunds = 0;
	let verified = 0;
	let subscriptionsVerified = 0;
	let subscriptionFailures = 0;
	const blockingFailures: SanitizedProviderFailure[] = [];
	const subscriptions: RazorpaySubscriptionAuditRow[] = [];
	const subscriptionActions: RazorpaySubscriptionAction[] = [];
	const payments: RazorpayPaymentAuditRow[] = [];
	const paymentActions: RazorpayPaymentAction[] = [];
	const paymentRecords = await db.collection("payments").get();
	const providerSubscriptions = new Map<
		string,
		{ billingPeriod: string | null; userId: string }
	>();
	for (const payment of paymentRecords.docs) {
		const data = payment.data();
		if (
			typeof data.razorpaySubscriptionId === "string" &&
			typeof data.userId === "string"
		) {
			providerSubscriptions.set(data.razorpaySubscriptionId, {
				billingPeriod: typeof data.plan === "string" ? data.plan : null,
				userId: data.userId,
			});
		}
	}
	for (const [subscriptionId, owner] of providerSubscriptions) {
		try {
			const entity = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/subscriptions/${encodeURIComponent(subscriptionId)}`,
			)) as RazorpaySubscriptionEntity;
			if (entity.id !== subscriptionId) {
				throw new Error("Razorpay returned a different subscription");
			}
			const normalized = normalizeRazorpaySubscription({
				billingPeriod: owner.billingPeriod,
				entity,
				userId: owner.userId,
			});
			const evaluated = evaluateSubscription(normalized);
			subscriptionsVerified += 1;
			subscriptions.push({
				effectiveEntitlement: evaluated.entitled,
				failureClass: null,
				firebaseUserExists: null,
				firebaseUserId: owner.userId,
				httpStatus: null,
				intendedAction: "normalize_and_reconcile",
				providerRef: providerReference("razorpay", subscriptionId),
				providerState: evaluated.state,
			});
			subscriptionActions.push({
				billingPeriod: owner.billingPeriod,
				entity,
				kind: "persist",
				subscriptionId,
				userId: owner.userId,
			});
		} catch (error) {
			const failure = classifyRazorpayProviderFailure(error);
			subscriptionFailures += 1;
			if (failure.blocking) blockingFailures.push(failure);
			subscriptions.push({
				effectiveEntitlement: false,
				failureClass: failure.failureClass,
				firebaseUserExists: null,
				firebaseUserId: owner.userId,
				httpStatus: failure.status,
				intendedAction: failure.blocking
					? "stop_before_writes"
					: "create_review_issue",
				providerRef: providerReference("razorpay", subscriptionId),
				providerState: null,
			});
			subscriptionActions.push({
				failure,
				kind: "issue",
				subscriptionId,
				userId: owner.userId,
			});
		}
	}
	for (const document of snapshot) {
		const data = document.data();
		const paymentId = data.providerTransactionId;
		if (typeof paymentId !== "string") continue;
		let payment: RazorpayPayment;
		try {
			payment = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/payments/${encodeURIComponent(paymentId)}`,
			)) as RazorpayPayment;
		} catch (error) {
			const failure = classifyRazorpayProviderFailure(error);
			payments.push({
				failureClass: failure.failureClass,
				httpStatus: failure.status,
				intendedAction: failure.blocking ? "stop_before_writes" : "quarantine",
				providerRef: providerReference("razorpay_payment", paymentId),
			});
			if (failure.blocking) {
				blockingFailures.push(failure);
				continue;
			}
			excluded += 1;
			projectedDocuments.set(document.id, {
				...data,
				environment: "unknown",
				validationStatus: "excluded",
			});
			paymentActions.push({
				data,
				document,
				kind: "exclude",
				reason: "provider_payment_not_found",
			});
			continue;
		}
		if (!isVerifiedRazorpayPayment(payment, paymentId)) {
			excluded += 1;
			projectedDocuments.set(document.id, {
				...data,
				environment: "unknown",
				validationStatus: "excluded",
			});
			payments.push({
				failureClass: "unresolved",
				httpStatus: null,
				intendedAction: "quarantine",
				providerRef: providerReference("razorpay_payment", paymentId),
			});
			paymentActions.push({
				data,
				document,
				kind: "exclude",
				reason: "provider_payment_not_captured",
			});
			continue;
		}
		const verifiedPayment = payment as Required<
			Pick<
				RazorpayPayment,
				"amount" | "captured" | "created_at" | "currency" | "id" | "status"
			>
		>;
		verified += 1;
		const normalizedPayment = {
			...data,
			amountMicros: minorUnitsToMicros(verifiedPayment.amount),
			currency: verifiedPayment.currency.toUpperCase(),
			environment: "production",
			occurredAt: Timestamp.fromMillis(verifiedPayment.created_at * 1000),
			validationStatus: "verified",
		};
		projectedDocuments.set(document.id, normalizedPayment);
		let response: { items?: RazorpayRefund[] };
		try {
			response = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/payments/${encodeURIComponent(paymentId)}/refunds`,
			)) as { items?: RazorpayRefund[] };
		} catch (error) {
			const classified = classifyRazorpayProviderFailure(error);
			const failure = { ...classified, blocking: true };
			blockingFailures.push(failure);
			payments.push({
				failureClass: failure.failureClass,
				httpStatus: failure.status,
				intendedAction: "stop_before_writes",
				providerRef: providerReference("razorpay_payment", paymentId),
			});
			continue;
		}
		const processedRefunds: VerifiedRazorpayRefund[] = [];
		for (const refund of response.items ?? []) {
			if (
				refund.status !== "processed" ||
				typeof refund.id !== "string" ||
				typeof refund.amount !== "number" ||
				typeof refund.currency !== "string" ||
				typeof refund.created_at !== "number"
			) continue;
			processedRefunds.push(refund as VerifiedRazorpayRefund);
			refunds += 1;
			if (!providerDocumentIds.has(refund.id)) {
				projectedDocuments.set(`projected_refund_${refund.id}`, {
					amountMicros: minorUnitsToMicros(refund.amount),
					currency: refund.currency.toUpperCase(),
					environment: "production",
					kind: "refund",
					occurredAt: Timestamp.fromMillis(refund.created_at * 1000),
					provider: "razorpay",
					providerTransactionId: refund.id,
					validationStatus: "verified",
				});
			}
		}
		payments.push({
			failureClass: null,
			httpStatus: null,
			intendedAction: "verify",
			providerRef: providerReference("razorpay_payment", paymentId),
		});
		paymentActions.push({
			data,
			document,
			kind: "verify",
			payment: verifiedPayment,
			refunds: processedRefunds,
		});
	}
	const ownerExists = new Map<string, boolean>();
	await forEachBounded(
		[...new Set([...providerSubscriptions.values()].map((owner) => owner.userId))],
		5,
		async (userId) => {
			try {
				ownerExists.set(
					userId,
					await identityToolkitUserExists({
						credential,
						projectId,
						uid: userId,
					}),
				);
			} catch {
				blockingFailures.push({
					blocking: true,
					failureClass: "retryable",
					status: null,
				});
			}
		},
	);
	for (const row of subscriptions) {
		const exists = ownerExists.get(row.firebaseUserId);
		row.firebaseUserExists = exists ?? null;
		if (exists === false && row.intendedAction === "normalize_and_reconcile") {
			row.intendedAction = "create_missing_user_issue";
		}
	}
	for (let index = 0; index < subscriptionActions.length; index += 1) {
		const action = subscriptionActions[index];
		if (action.kind === "persist" && ownerExists.get(action.userId) === false) {
			subscriptionActions[index] = {
				kind: "missing_user",
				subscriptionId: action.subscriptionId,
				userId: action.userId,
			};
		}
	}
	return {
		blockingFailures,
		excluded,
		paymentActions,
		payments,
		refunds,
		subscriptionActions,
		subscriptionFailures,
		subscriptions,
		subscriptionsVerified,
		verified,
		current: aggregateRevenueTransactions(
			allSnapshot.docs.map((document) => document.data()),
		).lifetime,
		projected: aggregateRevenueTransactions([...projectedDocuments.values()])
			.lifetime,
	};
}

async function applyRazorpayAudit(
	audit: RazorpayAudit,
	claimsAuth: SubscriptionClaimsAuth,
): Promise<void> {
	assertNoBlockingProviderFailures(audit.blockingFailures);
	for (const action of audit.subscriptionActions) {
		if (action.kind === "missing_user") {
			await recordSubscriptionIssue({
				details: { firebaseUserMissing: true },
				providerKey: action.subscriptionId,
				source: "razorpay",
				type: "razorpay_owner_missing",
				userId: action.userId,
			});
			await resolveUserSubscriptionIssues(
				action.userId,
				"claims_sync_failed",
			);
			continue;
		}
		if (action.kind === "issue") {
			if (action.failure.blocking) continue;
			await recordSubscriptionIssue({
				details: {
					failureClass: action.failure.failureClass,
					providerLookupFailed: true,
					providerStatus: action.failure.status,
				},
				providerKey: action.subscriptionId,
				source: "razorpay",
				type: "razorpay_verification_failed",
				userId: action.userId,
			});
			continue;
		}
		await persistVerifiedRazorpaySubscriptionRecord({
			billingPeriod: action.billingPeriod,
			entity: action.entity,
			reconcile: false,
			userId: action.userId,
		});
		await resolveSubscriptionIssues(action.subscriptionId, "razorpay");
	}
	for (const action of audit.paymentActions) {
		if (action.kind === "exclude") {
			await action.document.ref.set(
				{
					environment: "unknown",
					exclusionReason: action.reason,
					validatedAt: FieldValue.serverTimestamp(),
					validationStatus: "excluded",
				},
				{ merge: true },
			);
			continue;
		}
		const { payment } = action;
		await action.document.ref.set(
			{
				amountMicros: minorUnitsToMicros(payment.amount),
				currency: payment.currency.toUpperCase(),
				environment: "production",
				exclusionReason: FieldValue.delete(),
				monthKey: new Date(payment.created_at * 1000).toISOString().slice(0, 7),
				occurredAt: Timestamp.fromMillis(payment.created_at * 1000),
				validatedAt: FieldValue.serverTimestamp(),
				validationStatus: "verified",
			},
			{ merge: true },
		);
		for (const refund of action.refunds) {
			await enqueueRevenueEvent({
				amountMicros: minorUnitsToMicros(refund.amount),
				currency: refund.currency,
				environment: "production",
				kind: "refund",
				metadata: { paymentRef: providerReference("razorpay_payment", payment.id) },
				occurredAt: new Date(refund.created_at * 1000),
				provider: "razorpay",
				providerTransactionId: refund.id,
				userId:
					typeof action.data.userId === "string" ? action.data.userId : null,
			});
		}
	}
	for (const userId of verifiedReconciliationUserIds(audit.subscriptionActions)) {
		await reconcileUserEntitlement(userId, Date.now(), claimsAuth);
	}
}

type GooglePlaySubscriptionResource = Awaited<
	ReturnType<typeof getGooglePlaySubscription>
>;

interface PlayAuditEntry {
	refreshable: boolean;
	resource: GooglePlaySubscriptionResource | null;
	row: GooglePlayReconciliationRow;
}

interface PlayOrderAction {
	issueReason: "lookup_failed" | "purchase_token_missing" | null;
	order: GooglePlayOrder | null;
	orderId: string;
}

interface PlayAudit {
	blockingFailures: SanitizedProviderFailure[];
	knownFailures: number;
	knownGone: number;
	knownVerified: number;
	orderActions: PlayOrderAction[];
	recoveredOrders: number;
	reports: number;
	subscriptionActions: Map<string, PlayAuditEntry>;
	subscriptions: GooglePlayReconciliationRow[];
	unmatched: number;
}

async function auditPlay(): Promise<PlayAudit> {
	const configuredBucket = process.env.GOOGLE_PLAY_REPORT_BUCKET?.trim();
	const bucket = configuredBucket
		? normalizeGooglePlayReportBucket(configuredBucket)
		: null;
	const known = await db
		.collection("subscriptions")
		.where("source", "==", "play_store")
		.get();
	const knownByToken = new Map<string, Record<string, unknown>>();
	for (const document of known.docs) {
		const data = document.data();
		knownByToken.set(
			typeof data.purchaseToken === "string" ? data.purchaseToken : document.id,
			data,
		);
	}
	const auditByToken = new Map<
		string,
		PlayAuditEntry
	>();
	const auditTaskByToken = new Map<
		string,
		Promise<PlayAuditEntry>
	>();
	const statusByUser = new Map<
		string,
		Record<string, unknown> | null
	>();
	const userExists = new Map<string, boolean>();
	const firebaseCredential = app.options.credential ?? applicationDefault();
	const firebaseProjectId =
		app.options.projectId ?? process.env.GOOGLE_CLOUD_PROJECT;
	if (!firebaseProjectId) {
		throw new Error("A Firebase project is required for subscription reconciliation");
	}
	const firebaseStatus = async (
		userId: string | null,
	): Promise<Record<string, unknown> | null> => {
		if (!userId) return null;
		if (!statusByUser.has(userId)) {
			const snapshot = await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.get();
			statusByUser.set(userId, snapshot.data() ?? null);
		}
		return statusByUser.get(userId) ?? null;
	};
	const firebaseUserExists = async (userId: string | null): Promise<boolean> => {
		if (!userId) return false;
		if (!userExists.has(userId)) {
			userExists.set(
				userId,
				await identityToolkitUserExists({
					credential: firebaseCredential,
					projectId: firebaseProjectId,
					uid: userId,
				}),
			);
		}
		return userExists.get(userId) === true;
	};
	const providerErrorCode = (error: unknown): string | number | null => {
		const candidate = error as {
			code?: unknown;
			response?: { status?: unknown };
		};
		if (
			typeof candidate.code === "string" ||
			typeof candidate.code === "number"
		) {
			return candidate.code;
		}
		return typeof candidate.response?.status === "number"
			? candidate.response.status
			: null;
	};
	const auditToken = async (
		purchaseToken: string,
		storedData: Record<string, unknown> | null,
	): Promise<PlayAuditEntry> => {
		const existing = auditByToken.get(purchaseToken);
		if (existing) return existing;
		const inFlight = auditTaskByToken.get(purchaseToken);
		if (inFlight) return inFlight;
		const task = (async () => {
			const storedUserId =
				typeof storedData?.userId === "string" ? storedData.userId : null;
			let resource: Awaited<ReturnType<typeof getGooglePlaySubscription>>;
			try {
				resource = await getGooglePlaySubscription(purchaseToken);
			} catch (error) {
				const storedEvaluation = evaluateSubscription(storedData);
				const errorCode = providerErrorCode(error);
				const gone =
					errorCode === 410 && !storedEvaluation.entitled;
				const result = {
					refreshable: false,
					resource: null,
					row: buildGooglePlayReconciliationRow({
						firebaseLookup: "not_applicable",
						firebaseStatus: await firebaseStatus(storedUserId).catch(
							() => null,
						),
						linkedUserId: storedUserId,
						normalizedSubscription: storedData ?? {},
						providerKey: purchaseToken,
						storedUserId,
						verification: gone ? ("gone" as const) : ("failed" as const),
						verificationErrorCode: errorCode,
					}),
				};
				auditByToken.set(purchaseToken, result);
				return result;
			}
			const externalAccountId = googlePlayAccountId(resource);
			const candidateUserId = candidateGooglePlayUserId({
				externalAccountId,
				storedUserId,
			});
			let firebaseLookup: GooglePlayFirebaseLookup = candidateUserId
				? "not_found"
				: "not_applicable";
			let linkedUserId: string | null = null;
			if (candidateUserId) {
				try {
					if (await firebaseUserExists(candidateUserId)) {
						firebaseLookup = "verified";
						linkedUserId = candidateUserId;
					}
				} catch {
					firebaseLookup = "failed";
				}
			}
			let currentFirebaseStatus: Record<string, unknown> | null = null;
			if (linkedUserId) {
				try {
					currentFirebaseStatus = await firebaseStatus(linkedUserId);
				} catch {
					firebaseLookup = "failed";
				}
			}
			const normalizedSubscription = normalizeGooglePlaySubscription({
				productId:
					typeof storedData?.productId === "string"
						? storedData.productId
						: undefined,
				purchaseToken,
				resource,
				userId: linkedUserId,
			});
			const result = {
				refreshable: true,
				resource,
				row: buildGooglePlayReconciliationRow({
					externalAccountId,
					firebaseLookup,
					firebaseStatus: currentFirebaseStatus,
					linkedUserId,
					normalizedSubscription,
					providerKey: purchaseToken,
					storedUserId,
				}),
			};
			auditByToken.set(purchaseToken, result);
			return result;
		})();
		auditTaskByToken.set(purchaseToken, task);
		try {
			return await task;
		} finally {
			auditTaskByToken.delete(purchaseToken);
		}
	};
	let knownVerified = 0;
	let knownGone = 0;
	let knownFailures = 0;
	const knownSubscriptions = [...knownByToken];
	console.log(
		`Google Play audit: verifying ${knownSubscriptions.length} stored subscriptions`,
	);
	await forEachBounded(knownSubscriptions, 6, async ([purchaseToken, data]) => {
		const audited = await auditToken(purchaseToken, data);
		if (audited.row.verification === "failed") knownFailures += 1;
		else if (audited.row.verification === "gone") knownGone += 1;
		else knownVerified += 1;
	});
	let objects: string[] = [];
	if (bucket) {
		objects = await listGooglePlaySalesReports(bucket);
	} else {
		console.warn("Google Play reports: GOOGLE_PLAY_REPORT_BUCKET is not configured");
	}
	const orderIds = new Set<string>();
	if (bucket) {
		await forEachBounded(objects, 4, async (objectName) => {
			for (const row of await readGooglePlaySalesReport(bucket, objectName)) {
				if (!isGooglePlaySubscriptionSalesRow(row)) continue;
				const orderId = row["Order Number"]?.trim();
				if (orderId) orderIds.add(orderId);
			}
		});
	}
	console.log(
		`Google Play recovery: ${objects.length} reports, ${orderIds.size} distinct orders`,
	);
	let recoveredOrders = 0;
	let unresolvedOrders = 0;
	const orderActions: PlayOrderAction[] = [];
	await forEachBounded([...orderIds], 6, async (orderId) => {
		let order: Awaited<ReturnType<typeof getGooglePlayOrder>>;
		try {
			order = await getGooglePlayOrder(orderId);
		} catch {
			unresolvedOrders += 1;
			orderActions.push({ issueReason: "lookup_failed", order: null, orderId });
			return;
		}
		if (!order.purchaseToken) {
			unresolvedOrders += 1;
			orderActions.push({
				issueReason: "purchase_token_missing",
				order,
				orderId,
			});
			return;
		}
		recoveredOrders += 1;
		orderActions.push({ issueReason: null, order, orderId });
		await auditToken(
			order.purchaseToken,
			knownByToken.get(order.purchaseToken) ?? null,
		);
	});
	const subscriptions = markGooglePlayOverlaps(
		[...auditByToken.values()].map(({ row }) => row),
	);
	const unmatched =
		unresolvedOrders +
		subscriptions.filter((row) =>
			["unmatched", "verification_failed"].includes(row.classification),
		).length;
	const blockingFailures: SanitizedProviderFailure[] = [];
	for (const audited of auditByToken.values()) {
		if (audited.row.verification === "failed") {
			blockingFailures.push({
				blocking: true,
				failureClass: "retryable",
				status:
					typeof audited.row.verificationErrorCode === "number"
						? audited.row.verificationErrorCode
						: null,
			});
		}
	}
	for (let index = 0; index < unresolvedOrders; index += 1) {
		blockingFailures.push({
			blocking: true,
			failureClass: "retryable",
			status: null,
		});
	}
	return {
		blockingFailures,
		knownFailures,
		knownGone,
		knownVerified,
		orderActions,
		recoveredOrders,
		reports: objects.length,
		subscriptionActions: auditByToken,
		subscriptions,
		unmatched,
	};
}

async function applyPlayAudit(
	audit: PlayAudit,
	claimsAuth: SubscriptionClaimsAuth,
): Promise<void> {
	assertNoBlockingProviderFailures(audit.blockingFailures);
	const usersToReconcile = new Set<string>();
	for (const action of audit.orderActions) {
		if (action.issueReason) {
			await recordSubscriptionIssue({
				details:
					action.issueReason === "lookup_failed"
						? { ordersApiLookupFailed: true }
						: { purchaseTokenMissing: true },
				providerKey: action.orderId,
				source: "play_store",
				type: "play_order_unresolved",
			});
			continue;
		}
		if (action.order) {
			await enqueueVerifiedGooglePlayOrder(action.orderId, action.order);
		}
	}
	for (const [purchaseToken, audited] of audit.subscriptionActions) {
		if (!audited.refreshable || !audited.resource) {
			if (audited.row.verification === "failed") {
				await recordSubscriptionIssue({
					details: { providerLookupFailed: true },
					providerKey: purchaseToken,
					source: "play_store",
					type: "play_verification_failed",
					userId: audited.row.storedUserId,
				});
			}
			continue;
		}
		const refreshed = await persistVerifiedGooglePlaySubscription({
			purchaseToken,
			reconcile: false,
			requestedUserId: audited.row.firebaseUserId,
			resource: audited.resource,
			userExists: async (userId) =>
				audited.row.firebaseLookup === "verified" &&
				audited.row.firebaseUserId === userId,
		});
		if (refreshed.userId) usersToReconcile.add(refreshed.userId);
		if (audited.row.storedUserId) usersToReconcile.add(audited.row.storedUserId);
	}
	for (const userId of usersToReconcile) {
		await reconcileUserEntitlement(userId, Date.now(), claimsAuth);
	}
}

async function main(): Promise<void> {
	const execute = process.argv.includes("--execute");
	const selectedProvider = selectedBillingProvider();
	const includePlay = selectedProvider !== "razorpay";
	const includeRazorpay = selectedProvider !== "play";
	const resolvedProject = app.options.projectId ?? process.env.GOOGLE_CLOUD_PROJECT;
	const firebaseCredential = app.options.credential ?? applicationDefault();
	if (!resolvedProject) throw new Error("A Firebase project is required");
	const claimsAuth = identityToolkitClaimsAuth({
		credential: firebaseCredential,
		projectId: resolvedProject,
	});
	if (execute) {
		if (
			argument("project") !== EXPECTED_PROJECT ||
			argument("database") !== EXPECTED_DATABASE ||
			resolvedProject !== EXPECTED_PROJECT ||
			databaseId !== EXPECTED_DATABASE
		) throw new Error("Resolved and explicit Firebase targets must match production");
	}

	console.log(
		`Mode: ${execute ? "EXECUTE" : "DRY RUN"}; provider: ${selectedProvider}`,
	);
	const subscriptions = await db.collection("subscriptions").get();
	const storedRecords = subscriptions.docs.map((document) => document.data());
	const providerCounts = storedProviderCounts(storedRecords);
	const appStoreRows = subscriptions.docs
		.filter((document) => document.data().source === "app_store")
		.map((document) =>
			storedOnlySubscriptionRow({
				data: document.data(),
				providerKey: document.id,
			}),
		);
	const selectedStoredProviderRecords = subscriptions.docs.filter((document) => {
		const source = document.data().source;
		return (
			typeof source === "string" &&
			isAuthoritativelySelectedSource(selectedProvider, source)
		);
	});
	const openIssues = await db
		.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
		.where("status", "==", "open")
		.count()
		.get();
	console.log("Stored provider subscriptions (pre-reconciliation):", providerCounts);
	console.log(
		`Authoritatively selected stored provider records: ${selectedStoredProviderRecords.length}`,
	);
	console.log("App Store subscription audit (stored-only; no changes planned):");
	console.log(JSON.stringify(appStoreRows, null, 2));
	console.log(`Existing subscription issues: ${openIssues.data().count}`);

	const [razorpay, play] = await Promise.all([
		includeRazorpay
			? auditRazorpay({
					credential: firebaseCredential,
					projectId: resolvedProject,
				})
			: null,
		includePlay ? auditPlay() : null,
	]);
	if (razorpay) {
		console.log("Razorpay audit:", {
			blockingFailures: razorpay.blockingFailures.length,
			current: razorpay.current,
			excluded: razorpay.excluded,
			projected: razorpay.projected,
			refunds: razorpay.refunds,
			subscriptionFailures: razorpay.subscriptionFailures,
			subscriptionsVerified: razorpay.subscriptionsVerified,
			verified: razorpay.verified,
		});
		console.log("Razorpay subscription audit (provider identifiers redacted):");
		console.log(JSON.stringify(razorpay.subscriptions, null, 2));
		console.log("Razorpay payment audit (provider identifiers redacted):");
		console.log(JSON.stringify(razorpay.payments, null, 2));
	}
	if (play) {
		const {
			blockingFailures,
			orderActions,
			subscriptionActions,
			subscriptions: playSubscriptions,
			...playSummary
		} = play;
		console.log("Google Play recovery:", {
			...playSummary,
			blockingFailures: blockingFailures.length,
		});
		console.log("Google Play subscription audit (purchase tokens redacted):");
		console.log(formatGooglePlayReconciliationReport(playSubscriptions));
	}
	const blockingFailures = [
		...(razorpay?.blockingFailures ?? []),
		...(play?.blockingFailures ?? []),
	];
	await verifyFirebaseAuthPreflight({
		credential: firebaseCredential,
		projectId: resolvedProject,
	});
	console.log("Firebase Auth preflight: ready");
	if (execute) {
		await applyAfterProviderPreflight(blockingFailures, async () => {
			await confirmTarget();
			if (razorpay) await applyRazorpayAudit(razorpay, claimsAuth);
			if (play) await applyPlayAudit(play, claimsAuth);
		});
		const pendingEvents = await db
			.collection("adminRevenueEvents")
			.where("status", "==", "pending")
			.get();
		for (const event of pendingEvents.docs) {
			const eventProvider = event.data().input?.provider;
			if (
				selectedProvider === "all" ||
				(selectedProvider === "play" && eventProvider === "play_store") ||
				(selectedProvider === "razorpay" && eventProvider === "razorpay")
			) {
				await processRevenueEvent(event.id);
			}
		}
		const before = await db.collection("adminRevenueSummary").doc("lifetime").get();
		console.log("Old stored lifetime revenue:", revenueSummaryAmounts(before.data()));
		const rebuilt = await rebuildRevenueSummaries();
		const [finalSubscriptions, finalIssues] = await Promise.all([
			db.collection("subscriptions").get(),
			db
				.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
				.where("status", "==", "open")
				.get(),
		]);
		const subscriptionProviderCounts = providerSubscriptionCounts(
			finalSubscriptions.docs.map((document) => document.data()),
		);
		for (const issue of finalIssues.docs) {
			const source = issue.data().source;
			if (typeof source === "string" && subscriptionProviderCounts[source]) {
				subscriptionProviderCounts[source].unmatched += 1;
			}
		}
		const metricsUpdate: Record<string, unknown> = {
			subscriptionMetricsUpdatedAt: FieldValue.serverTimestamp(),
			subscriptionProviderCounts,
		};
		if (play) {
			metricsUpdate["revenueProviderStatus.play_store"] = {
				knownFailures: play.knownFailures,
				reports: play.reports,
				status:
					play.reports > 0 && play.knownFailures === 0
						? "ready"
						: "degraded",
				updatedAt: FieldValue.serverTimestamp(),
			};
		}
		if (razorpay) {
			metricsUpdate["revenueProviderStatus.razorpay"] = {
				excluded: razorpay.excluded,
				status: razorpay.excluded === 0 ? "ready" : "degraded",
				updatedAt: FieldValue.serverTimestamp(),
				verified: razorpay.verified,
			};
		}
		await db
			.collection(ADMIN_METRICS_COLLECTION)
			.doc("current")
			.set(metricsUpdate, { merge: true });
		console.log("Rebuilt lifetime revenue:", rebuilt.lifetime);
		console.log("Billing reconciliation complete.");
	} else {
		console.log(
			`Dry run complete. No data changed. Blocking provider failures: ${blockingFailures.length}.`,
		);
	}
}

main().catch((error: unknown) => {
	console.error(`Billing reconciliation failed (${sanitizedErrorCode(error)})`);
	process.exitCode = 1;
});
