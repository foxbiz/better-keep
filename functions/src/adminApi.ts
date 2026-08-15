import type { UserRecord } from "firebase-admin/auth";
import { FieldPath, Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import {
	type AdminAuthData,
	requireAdminAccess,
	requireRecentAdminAccess,
} from "./adminAccess";
import { executeAuditedAdminAction } from "./adminAudit";
import {
	ADMIN_ACCESS_CLAIM,
	ADMIN_BILLING_ACTIVITY_COLLECTION,
	ADMIN_METRICS_COLLECTION,
	ADMIN_REVENUE_COLLECTION,
	ADMIN_REVENUE_EVENT_COLLECTION,
	ADMIN_REVENUE_SUMMARY_COLLECTION,
	ADMIN_SUBSCRIPTION_ISSUE_COLLECTION,
	ADMIN_USER_COLLECTION,
	PAID_SUBSCRIPTION_SOURCES,
} from "./adminConfig";
import { mergedRevenueProviderStatus } from "./adminMetrics";
import { syncAdminUserIndex } from "./adminUserIndex";
import {
	BILLING_ACTIVITY_TYPES,
	type BillingActivityType,
} from "./billingActivity";
import { auth, db } from "./config";
import { monthKey, revenueSummaryAmounts } from "./revenueLedger";
import {
	isProtectedReviewUserRecord,
	REVIEW_ACCESS_CLAIM,
} from "./reviewAccess";
import { storedProviderSubscriptionCounts } from "./subscriptionMetrics";

export { providerSubscriptionCounts } from "./subscriptionMetrics";

type AdminUserSegment =
	| "all"
	| "cancelled"
	| "disabled"
	| "free"
	| "paid"
	| "trial";

interface ListUsersInput {
	cursor?: string;
	pageSize?: number;
	search?: string;
	segment?: AdminUserSegment;
}

interface ListBillingActivityInput {
	cursor?: string;
	eventType?: BillingActivityType;
	pageSize?: number;
	provider?: string;
}

interface UserLookupInput {
	uid: string;
}

interface UserActionInput extends UserLookupInput {
	requestId: string;
}

interface SetDisabledInput extends UserActionInput {
	disabled: boolean;
}

function requireString(value: unknown, label: string): string {
	if (typeof value !== "string" || value.trim().length === 0) {
		throw new HttpsError("invalid-argument", `${label} is required`);
	}
	return value.trim();
}

function iso(value: unknown): string | null {
	return value instanceof Timestamp ? value.toDate().toISOString() : null;
}

function serializeUser(data: Record<string, unknown>): Record<string, unknown> {
	return {
		uid: data.uid,
		email: data.email ?? null,
		displayName: data.displayName ?? null,
		photoURL: data.photoURL ?? null,
		providers: data.providers ?? [],
		disabled: data.disabled === true,
		emailVerified: data.emailVerified === true,
		isAdmin: data.isAdmin === true,
		isReviewAccount: data.isReviewAccount === true,
		authCreatedAt: iso(data.authCreatedAt),
		lastSignInAt: iso(data.lastSignInAt),
		lastSeen: iso(data.lastSeen),
		plan: data.plan ?? "free",
		subscriptionClass: data.subscriptionClass ?? "free",
		renewalState: data.renewalState ?? "none",
		subscriptionSource: data.subscriptionSource ?? null,
		subscriptionState: data.subscriptionState ?? null,
		billingPeriod: data.billingPeriod ?? null,
		subscriptionExpiresAt: iso(data.subscriptionExpiresAt),
	};
}

function parseCursor(value: string | undefined): {
	createdAt: Timestamp;
	uid: string;
} | null {
	if (!value) return null;
	try {
		const decoded = JSON.parse(
			Buffer.from(value, "base64url").toString("utf8"),
		) as {
			createdAt?: number;
			uid?: string;
		};
		if (
			typeof decoded.createdAt !== "number" ||
			!Number.isFinite(decoded.createdAt) ||
			typeof decoded.uid !== "string"
		) {
			throw new Error("invalid cursor");
		}
		return {
			createdAt: Timestamp.fromMillis(decoded.createdAt),
			uid: decoded.uid,
		};
	} catch {
		throw new HttpsError(
			"invalid-argument",
			"The pagination cursor is invalid",
		);
	}
}

function encodeCursor(data: Record<string, unknown>): string | null {
	const createdAt = data.authCreatedAt;
	const uid = data.uid;
	if (!(createdAt instanceof Timestamp) || typeof uid !== "string") return null;
	return Buffer.from(
		JSON.stringify({ createdAt: createdAt.toMillis(), uid }),
		"utf8",
	).toString("base64url");
}

function parseActivityCursor(value: string | undefined): {
	id: string;
	occurredAt: Timestamp;
} | null {
	if (!value) return null;
	try {
		const decoded = JSON.parse(
			Buffer.from(value, "base64url").toString("utf8"),
		) as { id?: string; occurredAt?: number };
		if (
			typeof decoded.id !== "string" ||
			typeof decoded.occurredAt !== "number" ||
			!Number.isFinite(decoded.occurredAt)
		) {
			throw new Error("invalid cursor");
		}
		return {
			id: decoded.id,
			occurredAt: Timestamp.fromMillis(decoded.occurredAt),
		};
	} catch {
		throw new HttpsError(
			"invalid-argument",
			"The billing activity cursor is invalid",
		);
	}
}

function encodeActivityCursor(
	document: FirebaseFirestore.QueryDocumentSnapshot,
): string | null {
	const occurredAt = document.data().occurredAt;
	if (!(occurredAt instanceof Timestamp)) return null;
	return Buffer.from(
		JSON.stringify({ id: document.id, occurredAt: occurredAt.toMillis() }),
		"utf8",
	).toString("base64url");
}

function segmentQuery(
	segment: AdminUserSegment,
): FirebaseFirestore.Query<FirebaseFirestore.DocumentData> {
	let query: FirebaseFirestore.Query = db.collection(ADMIN_USER_COLLECTION);
	if (segment === "paid") {
		query = query.where("subscriptionClass", "==", "paid");
	} else if (segment === "cancelled") {
		query = query
			.where("subscriptionClass", "==", "paid")
			.where("renewalState", "==", "cancelled");
	} else if (segment === "trial" || segment === "free") {
		query = query.where("subscriptionClass", "==", segment);
	} else if (segment === "disabled") {
		query = query.where("disabled", "==", true);
	}
	return query;
}

export function matchesAdminUserSegment(
	data: Record<string, unknown>,
	segment: AdminUserSegment,
): boolean {
	if (segment === "all") return true;
	if (segment === "disabled") return data.disabled === true;
	if (segment === "cancelled") {
		return (
			data.subscriptionClass === "paid" && data.renewalState === "cancelled"
		);
	}
	return data.subscriptionClass === segment;
}

async function searchUsers(
	search: string,
	segment: AdminUserSegment,
	pageSize: number,
) {
	const normalized = search.toLowerCase();
	const [exactUid, ...snapshots] = await Promise.all([
		db.collection(ADMIN_USER_COLLECTION).doc(search).get(),
		...["emailLower", "displayNameLower"].map((field) =>
			segmentQuery(segment)
				.orderBy(field)
				.startAt(normalized)
				.endAt(`${normalized}\uf8ff`)
				.limit(pageSize)
				.get(),
		),
	]);
	const documents = new Map<string, FirebaseFirestore.DocumentSnapshot>();
	for (const snapshot of snapshots) {
		for (const document of snapshot.docs) documents.set(document.id, document);
	}
	const sorted = [...documents.values()].sort((a, b) => {
		const left = a.data() ?? {};
		const right = b.data() ?? {};
		return (
			String(left.emailLower ?? "").localeCompare(
				String(right.emailLower ?? ""),
			) ||
			String(left.displayNameLower ?? "").localeCompare(
				String(right.displayNameLower ?? ""),
			) ||
			a.id.localeCompare(b.id)
		);
	});
	if (
		exactUid.exists &&
		matchesAdminUserSegment(exactUid.data() ?? {}, segment)
	) {
		sorted.unshift(exactUid);
	}
	return [
		...new Map(sorted.map((document) => [document.id, document])).values(),
	].slice(0, pageSize);
}

function requestAuth<T>(
	request: CallableRequest<T>,
	recent = false,
): AdminAuthData {
	const authData = request.auth as AdminAuthData | undefined;
	return recent
		? requireRecentAdminAccess(authData)
		: requireAdminAccess(authData);
}

function serializeCurrencies(
	currencies: Record<string, number>,
	allowNegative = false,
) {
	return Object.entries(currencies)
		.map(([currency, amountMicros]) => ({
			currency,
			amountMicros: String(
				allowNegative
					? Number(amountMicros) || 0
					: Math.max(0, Number(amountMicros) || 0),
			),
		}))
		.sort((a, b) => a.currency.localeCompare(b.currency));
}

function serializeProviderStatus(value: unknown): Record<string, unknown> {
	if (!value || typeof value !== "object") return {};
	return Object.fromEntries(
		Object.entries(value as Record<string, unknown>).map(([provider, raw]) => {
			const data =
				raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
			return [
				provider,
				{
					...data,
					updatedAt: iso(data.updatedAt),
				},
			];
		}),
	);
}

function serializeRevenueCoverage(value: unknown): Record<string, unknown> {
	if (!value || typeof value !== "object") return {};
	return Object.fromEntries(
		Object.entries(value as Record<string, unknown>).map(([provider, raw]) => {
			const data =
				raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
			return [
				provider,
				{
					startedAt: iso(data.startedAt),
					lastRecordedAt: iso(data.lastRecordedAt),
				},
			];
		}),
	);
}

export const adminGetOverview = onCall(
	{ enforceAppCheck: true },
	async (request) => {
		requestAuth(request);
		const currentMonth = monthKey(new Date());
		const [
			metrics,
			lifetimeRevenue,
			monthlyRevenue,
			paidCount,
			cancelledCount,
			pendingRevenue,
			retryingRevenue,
			deadLetterRevenue,
			openSubscriptionIssues,
			quarantinedSubscriptionIssues,
			excludedRevenue,
		] = await Promise.all([
			db.collection(ADMIN_METRICS_COLLECTION).doc("current").get(),
			db.collection(ADMIN_REVENUE_SUMMARY_COLLECTION).doc("lifetime").get(),
			db
				.collection(ADMIN_REVENUE_SUMMARY_COLLECTION)
				.doc(`month_${currentMonth}`)
				.get(),
			db
				.collection(ADMIN_USER_COLLECTION)
				.where("subscriptionClass", "==", "paid")
				.count()
				.get(),
			db
				.collection(ADMIN_USER_COLLECTION)
				.where("subscriptionClass", "==", "paid")
				.where("renewalState", "==", "cancelled")
				.count()
				.get(),
			db
				.collection(ADMIN_REVENUE_EVENT_COLLECTION)
				.where("status", "==", "pending")
				.count()
				.get(),
			db
				.collection(ADMIN_REVENUE_EVENT_COLLECTION)
				.where("status", "in", ["processing", "failed"])
				.count()
				.get(),
			db
				.collection(ADMIN_REVENUE_EVENT_COLLECTION)
				.where("status", "==", "dead_letter")
				.count()
				.get(),
			db
				.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
				.where("status", "==", "open")
				.count()
				.get(),
			db
				.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
				.where("status", "==", "quarantined")
				.count()
				.get(),
			db
				.collection(ADMIN_REVENUE_COLLECTION)
				.where("validationStatus", "==", "excluded")
				.count()
				.get(),
		]);
		const metricsData = metrics.data();
		const storedTotalUsers = Number(metricsData?.totalUsers);
		let totalUsers = storedTotalUsers;
		let totalUsersUpdatedAt = iso(
			metricsData?.totalUsersUpdatedAt ?? metricsData?.updatedAt,
		);
		if (!Number.isFinite(storedTotalUsers) || storedTotalUsers < 0) {
			const fallback = await db.collection(ADMIN_USER_COLLECTION).count().get();
			totalUsers = fallback.data().count;
			totalUsersUpdatedAt = null;
		}

		const subscriptionCounts = storedProviderSubscriptionCounts(
			metricsData?.subscriptionProviderCounts,
		);
		const lifetimeAmounts = revenueSummaryAmounts(lifetimeRevenue.data());
		const monthlyAmounts = revenueSummaryAmounts(monthlyRevenue.data());
		const providerStatuses = serializeProviderStatus(
			mergedRevenueProviderStatus(metricsData),
		);

		return {
			schemaVersion: 2,
			generatedAt: new Date().toISOString(),
			totalUsersUpdatedAt,
			revenueUpdatedAt: iso(
				metricsData?.revenueUpdatedAt ?? metricsData?.updatedAt,
			),
			totalUsers,
			paidUsers: paidCount.data().count,
			cancelledUsers: cancelledCount.data().count,
			subscriptions: {
				byProvider: subscriptionCounts,
				updatedAt: iso(metricsData?.subscriptionMetricsUpdatedAt),
			},
			revenue: {
				currencyUnit: "micros",
				currentMonth,
				timezone: "UTC",
				lifetime: {
					gross: serializeCurrencies(lifetimeAmounts.grossCurrencies),
					refunds: serializeCurrencies(lifetimeAmounts.refundCurrencies),
					net: serializeCurrencies(lifetimeAmounts.netCurrencies, true),
				},
				monthly: {
					gross: serializeCurrencies(monthlyAmounts.grossCurrencies),
					refunds: serializeCurrencies(monthlyAmounts.refundCurrencies),
					net: serializeCurrencies(monthlyAmounts.netCurrencies, true),
				},
				coverage: serializeRevenueCoverage(metricsData?.revenueCoverage),
			},
			revenuePipeline: {
				pending: pendingRevenue.data().count,
				retrying: retryingRevenue.data().count,
				deadLetter: deadLetterRevenue.data().count,
				excludedTransactions: excludedRevenue.data().count,
				unmatchedSubscriptions: openSubscriptionIssues.data().count,
				providers: providerStatuses,
			},
			health: {
				actionable: {
					pendingRevenue: pendingRevenue.data().count,
					retryingRevenue: retryingRevenue.data().count,
					deadLetterRevenue: deadLetterRevenue.data().count,
					subscriptionIssues: openSubscriptionIssues.data().count,
				},
				quarantined: {
					revenueTransactions: excludedRevenue.data().count,
					subscriptionIssues: quarantinedSubscriptionIssues.data().count,
				},
				providers: providerStatuses,
			},
		};
	},
);

export const adminListBillingActivity = onCall<ListBillingActivityInput>(
	{ enforceAppCheck: true },
	async (request) => {
		requestAuth(request);
		const input =
			request.data && typeof request.data === "object" ? request.data : {};
		const requestedPageSize = input.pageSize ?? 25;
		if (!Number.isInteger(requestedPageSize)) {
			throw new HttpsError("invalid-argument", "pageSize must be an integer");
		}
		const pageSize = Math.min(Math.max(requestedPageSize, 1), 100);
		const provider = input.provider;
		if (
			provider !== undefined &&
			!(PAID_SUBSCRIPTION_SOURCES as readonly string[]).includes(provider)
		) {
			throw new HttpsError("invalid-argument", "Unknown billing provider");
		}
		const eventType = input.eventType;
		if (
			eventType !== undefined &&
			!(BILLING_ACTIVITY_TYPES as readonly string[]).includes(eventType)
		) {
			throw new HttpsError("invalid-argument", "Unknown billing activity type");
		}

		let query: FirebaseFirestore.Query = db.collection(
			ADMIN_BILLING_ACTIVITY_COLLECTION,
		);
		if (provider) query = query.where("provider", "==", provider);
		if (eventType) query = query.where("eventType", "==", eventType);
		query = query
			.orderBy("occurredAt", "desc")
			.orderBy(FieldPath.documentId(), "desc")
			.limit(pageSize + 1);
		const cursor = parseActivityCursor(input.cursor);
		if (cursor) query = query.startAfter(cursor.occurredAt, cursor.id);
		const snapshot = await query.get();
		const hasMore = snapshot.docs.length > pageSize;
		const page = snapshot.docs.slice(0, pageSize);

		const userIds = [
			...new Set(
				page
					.map((document) => document.data().userId)
					.filter((value): value is string => typeof value === "string"),
			),
		];
		const revenueEventIds = [
			...new Set(
				page
					.map((document) => document.data().revenueEventId)
					.filter((value): value is string => typeof value === "string"),
			),
		];
		const refs = [
			...userIds.map((uid) => db.collection(ADMIN_USER_COLLECTION).doc(uid)),
			...revenueEventIds.map((id) =>
				db.collection(ADMIN_REVENUE_EVENT_COLLECTION).doc(id),
			),
		];
		const related = refs.length > 0 ? await db.getAll(...refs) : [];
		const relatedByPath = new Map(
			related.map((document) => [document.ref.path, document.data() ?? null]),
		);

		return {
			activities: page.map((document) => {
				const data = document.data();
				const userId = typeof data.userId === "string" ? data.userId : null;
				const revenueEventId =
					typeof data.revenueEventId === "string" ? data.revenueEventId : null;
				const customer = userId
					? relatedByPath.get(
							db.collection(ADMIN_USER_COLLECTION).doc(userId).path,
						)
					: null;
				const revenueEvent = revenueEventId
					? relatedByPath.get(
							db.collection(ADMIN_REVENUE_EVENT_COLLECTION).doc(revenueEventId)
								.path,
						)
					: null;
				return {
					id: document.id,
					provider: data.provider,
					eventType: data.eventType,
					occurredAt: iso(data.occurredAt),
					origin: data.origin ?? "live",
					billingPeriod: data.billingPeriod ?? null,
					environment: data.environment ?? "unknown",
					subscriptionState: data.subscriptionState ?? null,
					entitlementState: data.entitlementState ?? null,
					amountMicros:
						Number.isSafeInteger(data.amountMicros) && data.amountMicros >= 0
							? String(data.amountMicros)
							: null,
					currency: typeof data.currency === "string" ? data.currency : null,
					revenueKind: data.revenueKind ?? null,
					revenueStatus:
						typeof revenueEvent?.status === "string"
							? revenueEvent.status
							: (data.revenueStatus ?? null),
					customer: userId
						? {
								uid: userId,
								email: customer?.email ?? null,
								displayName: customer?.displayName ?? null,
							}
						: null,
				};
			}),
			nextCursor:
				hasMore && page.length > 0
					? encodeActivityCursor(
							page.at(-1) as FirebaseFirestore.QueryDocumentSnapshot,
						)
					: null,
		};
	},
);

export const adminListUsers = onCall<ListUsersInput>(
	{ enforceAppCheck: true },
	async (request) => {
		requestAuth(request);
		const requestedPageSize = request.data.pageSize ?? 25;
		if (!Number.isInteger(requestedPageSize)) {
			throw new HttpsError("invalid-argument", "pageSize must be an integer");
		}
		const pageSize = Math.min(Math.max(requestedPageSize, 1), 100);
		const segment = request.data.segment ?? "all";
		const allowedSegments: AdminUserSegment[] = [
			"all",
			"paid",
			"cancelled",
			"trial",
			"free",
			"disabled",
		];
		if (!allowedSegments.includes(segment)) {
			throw new HttpsError("invalid-argument", "Unknown user segment");
		}
		if (
			request.data.search !== undefined &&
			typeof request.data.search !== "string"
		) {
			throw new HttpsError("invalid-argument", "Search must be a string");
		}
		const search = request.data.search?.trim();
		if (search) {
			if (search.length < 2 || search.length > 160) {
				throw new HttpsError(
					"invalid-argument",
					"Search must contain between 2 and 160 characters",
				);
			}
			const docs = await searchUsers(search, segment, pageSize);
			return {
				users: docs.map((doc) => serializeUser(doc.data() ?? {})),
				nextCursor: null,
			};
		}

		const cursor = parseCursor(request.data.cursor);
		let query = segmentQuery(segment)
			.orderBy("authCreatedAt", "desc")
			.orderBy("uid")
			.limit(pageSize + 1);
		if (cursor) query = query.startAfter(cursor.createdAt, cursor.uid);
		const snapshot = await query.get();
		const hasMore = snapshot.docs.length > pageSize;
		const page = snapshot.docs.slice(0, pageSize);
		return {
			users: page.map((doc) => serializeUser(doc.data())),
			nextCursor:
				hasMore && page.length > 0
					? encodeCursor(page.at(-1)?.data() ?? {})
					: null,
		};
	},
);

export const adminGetUser = onCall<UserLookupInput>(
	{ enforceAppCheck: true },
	async (request) => {
		requestAuth(request);
		const uid = requireString(request.data.uid, "User ID");
		await syncAdminUserIndex(uid);
		const snapshot = await db.collection(ADMIN_USER_COLLECTION).doc(uid).get();
		if (!snapshot.exists) throw new HttpsError("not-found", "User not found");
		return { user: serializeUser(snapshot.data() ?? {}) };
	},
);

function isProtectedTarget(user: UserRecord): boolean {
	return (
		user.customClaims?.[ADMIN_ACCESS_CLAIM] === true ||
		isProtectedReviewUserRecord(user) ||
		user.customClaims?.[REVIEW_ACCESS_CLAIM] === true
	);
}

export const adminSetUserDisabled = onCall<SetDisabledInput>(
	{ enforceAppCheck: true, consumeAppCheckToken: true },
	async (request) => {
		const admin = requestAuth(request, true);
		const uid = requireString(request.data.uid, "User ID");
		const requestId = requireString(request.data.requestId, "requestId");
		if (typeof request.data.disabled !== "boolean") {
			throw new HttpsError(
				"invalid-argument",
				"Disabled status must be boolean",
			);
		}
		const target = await auth.getUser(uid);
		if (isProtectedTarget(target)) {
			throw new HttpsError(
				"failed-precondition",
				"Protected administrator and review accounts cannot be changed here",
			);
		}
		return executeAuditedAdminAction({
			requestId,
			admin,
			action: request.data.disabled ? "user.disabled" : "user.enabled",
			target,
			metadata: {
				desiredDisabled: request.data.disabled,
				revokeSessions: request.data.disabled,
			},
			performAuthMutation: async (markMutationStarted) => {
				markMutationStarted();
				const updated = await auth.updateUser(uid, {
					disabled: request.data.disabled,
				});
				if (request.data.disabled) await auth.revokeRefreshTokens(uid);
				return { success: true, disabled: updated.disabled };
			},
			synchronizeIndex: () => syncAdminUserIndex(uid),
		});
	},
);

export const adminRevokeUserSessions = onCall<UserActionInput>(
	{ enforceAppCheck: true, consumeAppCheckToken: true },
	async (request) => {
		const admin = requestAuth(request, true);
		const uid = requireString(request.data.uid, "User ID");
		const requestId = requireString(request.data.requestId, "requestId");
		const target = await auth.getUser(uid);
		if (isProtectedTarget(target)) {
			throw new HttpsError(
				"failed-precondition",
				"Protected administrator and review accounts cannot be changed here",
			);
		}
		return executeAuditedAdminAction({
			requestId,
			admin,
			action: "user.sessions_revoked",
			target,
			performAuthMutation: async (markMutationStarted) => {
				markMutationStarted();
				await auth.revokeRefreshTokens(uid);
				return { success: true };
			},
			synchronizeIndex: () => syncAdminUserIndex(uid),
		});
	},
);
