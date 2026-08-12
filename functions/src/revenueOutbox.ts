import { createHash } from "node:crypto";
import { Timestamp } from "firebase-admin/firestore";
import { error as logError } from "firebase-functions/logger";
import { ADMIN_REVENUE_EVENT_COLLECTION } from "./adminConfig";
import { db } from "./config";
import {
	type RevenueTransactionInput,
	recordRevenueTransaction,
} from "./revenueLedger";

const MAX_ATTEMPTS = 10;
const LEASE_MILLIS = 5 * 60 * 1000;

export function revenueEventId(
	input: Pick<RevenueTransactionInput, "provider" | "providerTransactionId">,
): string {
	return createHash("sha256")
		.update(`${input.provider}\0${input.providerTransactionId}`)
		.digest("hex");
}

export function revenueRetryDelayMillis(attempt: number): number {
	const exponent = Math.max(0, Math.min(attempt - 1, 20));
	return Math.min(6 * 60 * 60 * 1000, 30_000 * 2 ** exponent);
}

export function revenueFailureState(
	attempts: number,
	failedAtMillis: number,
): { status: "dead_letter" | "failed"; nextAttemptAtMillis: number | null } {
	if (attempts >= MAX_ATTEMPTS) {
		return { status: "dead_letter", nextAttemptAtMillis: null };
	}
	return {
		status: "failed",
		nextAttemptAtMillis: failedAtMillis + revenueRetryDelayMillis(attempts),
	};
}

export function revenueEventData(
	input: RevenueTransactionInput,
): Record<string, unknown> {
	return {
		input: {
			...input,
			occurredAt: Timestamp.fromDate(input.occurredAt),
		},
		status: "pending",
		attempts: 0,
		createdAt: Timestamp.now(),
		updatedAt: Timestamp.now(),
	};
}

export async function enqueueRevenueEvent(
	input: RevenueTransactionInput,
): Promise<string> {
	const id = revenueEventId(input);
	await db.runTransaction(async (transaction) => {
		await enqueueRevenueEventInTransaction(transaction, input);
	});
	return id;
}

export async function enqueueRevenueEventInTransaction(
	transaction: FirebaseFirestore.Transaction,
	input: RevenueTransactionInput,
): Promise<string> {
	const id = revenueEventId(input);
	const ref = db.collection(ADMIN_REVENUE_EVENT_COLLECTION).doc(id);
	const existing = await transaction.get(ref);
	if (!existing.exists) transaction.create(ref, revenueEventData(input));
	return id;
}

function deserializeInput(value: unknown): RevenueTransactionInput {
	if (!value || typeof value !== "object")
		throw new Error("Revenue event input is missing");
	const data = value as Record<string, unknown>;
	const occurredAt = data.occurredAt;
	if (!(occurredAt instanceof Timestamp))
		throw new Error("Revenue event date is invalid");
	return {
		provider: data.provider as RevenueTransactionInput["provider"],
		providerTransactionId: String(data.providerTransactionId ?? ""),
		userId: typeof data.userId === "string" ? data.userId : null,
		amountMicros: Number(data.amountMicros),
		currency: String(data.currency ?? ""),
		kind: data.kind as RevenueTransactionInput["kind"],
		environment: data.environment as RevenueTransactionInput["environment"],
		occurredAt: occurredAt.toDate(),
		metadata:
			data.metadata && typeof data.metadata === "object"
				? (data.metadata as Record<string, unknown>)
				: {},
	};
}

function safeErrorCode(error: unknown): string {
	const code = (error as { code?: unknown })?.code;
	if (typeof code === "string") return code.slice(0, 120);
	return error instanceof Error ? error.name.slice(0, 120) : "unknown";
}

export async function processRevenueEvent(
	eventId: string,
): Promise<"processed" | "skipped"> {
	const ref = db.collection(ADMIN_REVENUE_EVENT_COLLECTION).doc(eventId);
	const now = Timestamp.now();
	const claimed = await db.runTransaction(async (transaction) => {
		const snapshot = await transaction.get(ref);
		if (!snapshot.exists) return null;
		const data = snapshot.data() ?? {};
		if (data.status === "processed" || data.status === "dead_letter")
			return null;
		if (
			data.status === "processing" &&
			data.leaseUntil instanceof Timestamp &&
			data.leaseUntil.toMillis() > now.toMillis()
		)
			return null;
		if (
			data.status === "failed" &&
			data.nextAttemptAt instanceof Timestamp &&
			data.nextAttemptAt.toMillis() > now.toMillis()
		)
			return null;
		const attempts = Math.max(0, Number(data.attempts) || 0) + 1;
		let input: RevenueTransactionInput;
		try {
			input = deserializeInput(data.input);
		} catch (error) {
			const invalidErrorCode = safeErrorCode(error);
			transaction.update(ref, {
				status: "dead_letter",
				attempts,
				lastErrorCode: invalidErrorCode,
				lastFailedAt: now,
				updatedAt: now,
			});
			return { attempts, invalidErrorCode };
		}
		transaction.update(ref, {
			status: "processing",
			attempts,
			leaseUntil: Timestamp.fromMillis(now.toMillis() + LEASE_MILLIS),
			updatedAt: now,
		});
		return { attempts, input };
	});
	if (!claimed) return "skipped";
	if ("invalidErrorCode" in claimed) {
		logError("Revenue event moved to the dead-letter queue", {
			event: "admin_revenue_dead_letter",
			eventId,
			attempts: claimed.attempts,
			errorCode: claimed.invalidErrorCode,
		});
		return "skipped";
	}

	try {
		await recordRevenueTransaction(claimed.input);
		await ref.update({
			status: "processed",
			processedAt: Timestamp.now(),
			updatedAt: Timestamp.now(),
			leaseUntil: null,
			nextAttemptAt: null,
		});
		return "processed";
	} catch (error) {
		const failedAt = Timestamp.now();
		const failure = revenueFailureState(claimed.attempts, failedAt.toMillis());
		await ref.update({
			status: failure.status,
			lastErrorCode: safeErrorCode(error),
			lastFailedAt: failedAt,
			updatedAt: failedAt,
			leaseUntil: null,
			nextAttemptAt:
				failure.nextAttemptAtMillis === null
					? null
					: Timestamp.fromMillis(failure.nextAttemptAtMillis),
		});
		logError("Revenue event processing failed", {
			event:
				failure.status === "dead_letter"
					? "admin_revenue_dead_letter"
					: "admin_revenue_retry_scheduled",
			eventId,
			attempts: claimed.attempts,
			status: failure.status,
			errorCode: safeErrorCode(error),
		});
		if (failure.status !== "dead_letter") throw error;
		return "skipped";
	}
}
