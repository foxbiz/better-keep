import type { UserRecord } from "firebase-admin/auth";
import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import type { AdminAuthData } from "./adminAccess";
import { ADMIN_AUDIT_COLLECTION } from "./adminConfig";
import { db } from "./config";

export type AdminAction =
	| "user.disabled"
	| "user.enabled"
	| "user.sessions_revoked";

export interface AdminActionIdentity {
	action: AdminAction;
	adminUid: string;
	targetUid: string;
}

export function isUuid(value: unknown): value is string {
	return (
		typeof value === "string" &&
		/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
			value,
		)
	);
}

export function sameAdminAction(
	data: Record<string, unknown>,
	identity: AdminActionIdentity,
): boolean {
	return (
		data.action === identity.action &&
		data.adminUid === identity.adminUid &&
		data.targetUid === identity.targetUid
	);
}

function errorCode(error: unknown): string {
	const code = (error as { code?: unknown })?.code;
	return typeof code === "string" ? code.slice(0, 120) : "unknown";
}

export async function runAuditedMutation<T>({
	start,
	performAuthMutation,
	synchronizeIndex,
	markSucceeded,
	markFailed,
	markPendingError,
}: {
	start: () => Promise<{ execute: true } | { execute: false; result: T }>;
	performAuthMutation: (markMutationStarted: () => void) => Promise<T>;
	synchronizeIndex: () => Promise<void>;
	markSucceeded: (result: T) => Promise<void>;
	markFailed: (error: unknown) => Promise<void>;
	markPendingError: (error: unknown) => Promise<void>;
}): Promise<T> {
	const decision = await start();
	if (!decision.execute) return decision.result;
	let authMutationCompleted = false;
	try {
		const result = await performAuthMutation(() => {
			authMutationCompleted = true;
		});
		authMutationCompleted = true;
		await synchronizeIndex();
		await markSucceeded(result);
		return result;
	} catch (error) {
		if (authMutationCompleted) {
			await markPendingError(error).catch(() => undefined);
		} else {
			await markFailed(error);
		}
		throw error;
	}
}

export async function executeAuditedAdminAction<
	T extends Record<string, unknown>,
>({
	requestId,
	admin,
	target,
	action,
	metadata = {},
	performAuthMutation,
	synchronizeIndex,
}: {
	requestId: string;
	admin: AdminAuthData;
	target: UserRecord;
	action: AdminAction;
	metadata?: Record<string, unknown>;
	performAuthMutation: (markMutationStarted: () => void) => Promise<T>;
	synchronizeIndex: () => Promise<void>;
}): Promise<T> {
	if (!isUuid(requestId)) {
		throw new HttpsError("invalid-argument", "requestId must be a UUID");
	}
	const auditRef = db.collection(ADMIN_AUDIT_COLLECTION).doc(requestId);
	const identity: AdminActionIdentity = {
		action,
		adminUid: admin.uid,
		targetUid: target.uid,
	};
	const start = async () =>
		db.runTransaction(async (transaction) => {
			const existing = await transaction.get(auditRef);
			if (existing.exists) {
				const data = existing.data() ?? {};
				if (!sameAdminAction(data, identity)) {
					throw new HttpsError(
						"already-exists",
						"requestId is already assigned to a different action",
					);
				}
				if (
					data.status === "succeeded" &&
					data.result &&
					typeof data.result === "object"
				) {
					return { execute: false as const, result: data.result as T };
				}
				if (data.status === "pending") {
					throw new HttpsError(
						"aborted",
						"This admin action is still pending reconciliation",
					);
				}
				throw new HttpsError(
					"failed-precondition",
					"This admin action previously failed",
				);
			}
			transaction.create(auditRef, {
				...identity,
				adminEmail:
					typeof admin.token.email === "string" ? admin.token.email : null,
				targetEmail: target.email ?? null,
				metadata,
				status: "pending",
				requestedAt: Timestamp.now(),
			});
			return { execute: true as const };
		});
	return runAuditedMutation<T>({
		start,
		performAuthMutation,
		synchronizeIndex,
		markSucceeded: async (result) => {
			await auditRef.update({
				status: "succeeded",
				result,
				completedAt: Timestamp.now(),
			});
		},
		markFailed: async (error) => {
			await auditRef.update({
				status: "failed",
				errorCode: errorCode(error),
				completedAt: Timestamp.now(),
			});
		},
		markPendingError: async (error) => {
			await auditRef.update({
				lastErrorCode: errorCode(error),
				lastAttemptAt: Timestamp.now(),
			});
		},
	});
}
