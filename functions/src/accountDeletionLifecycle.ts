import { randomUUID } from "node:crypto";
import {
	type DocumentData,
	FieldValue,
	type Firestore,
	Timestamp,
} from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

export const DELETION_GRACE_MS = 30 * 24 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;
const LEASE_MS = 15 * 60 * 1000;
const AUDIT_COLLECTION = "accountDeletionRequests";
// ID tokens live for one hour. Allow five minutes for clock skew/in-flight refresh.
export const DELETION_TOKEN_DRAIN_MS = 65 * 60 * 1000;

export function requireDeletionEnabled(): void {
	if (process.env.ACCOUNT_DELETION_ENABLED !== "true") {
		throw new HttpsError(
			"unavailable",
			"Account deletion is temporarily paused. Contact support@betterkeep.app.",
			{ reason: "account-deletion-paused" },
		);
	}
}

export function deletionDateLabel(date: Timestamp): string {
	return `${date.toDate().toLocaleString("en-US", {
		year: "numeric",
		month: "long",
		day: "numeric",
		hour: "2-digit",
		minute: "2-digit",
		timeZone: "UTC",
		hourCycle: "h23",
	})} UTC`;
}

/** OTP consumption and the request record commit together, exactly once. */
export async function scheduleDeletion(
	db: Firestore,
	uid: string,
	otp: string,
	now = Timestamp.now(),
) {
	const userRef = db.collection("users").doc(uid);
	const otpRef = userRef.collection("otpVerification").doc("deletion");
	const requestId = randomUUID();
	const result = await db.runTransaction(async (tx) => {
		const user = await tx.get(userRef);
		const code = await tx.get(otpRef);
		if (!user.exists)
			throw new HttpsError("not-found", "User document not found");
		if (user.data()?.scheduledDeletion != null) {
			throw new HttpsError(
				"failed-precondition",
				"Cancel the existing deletion request first",
			);
		}
		const data = code.data();
		if (
			!data ||
			!(data.expiresAt instanceof Timestamp) ||
			data.expiresAt.toMillis() <= now.toMillis()
		) {
			throw new HttpsError(
				"deadline-exceeded",
				"Request a new verification code",
			);
		}
		const cancelledAt = user.data()?.deletionCancelledAt;
		if (
			!(data.createdAt instanceof Timestamp) ||
			(cancelledAt instanceof Timestamp &&
				data.createdAt.toMillis() < cancelledAt.toMillis())
		) {
			throw new HttpsError(
				"failed-precondition",
				"Request a new verification code after signing in",
			);
		}
		const attempts = Number(data.attempts) || 0;
		if (attempts >= 5)
			throw new HttpsError(
				"resource-exhausted",
				"Request a new verification code",
			);
		if (data.otp !== otp) {
			tx.update(otpRef, { attempts: attempts + 1 });
			return null; // Commit the failed attempt before throwing outside the transaction.
		}
		const schedule = {
			version: 2,
			requestId,
			state: "revoking",
			scheduledAt: now,
			deleteAt: Timestamp.fromMillis(now.toMillis() + DELETION_GRACE_MS),
			reminderAt: Timestamp.fromMillis(
				now.toMillis() + DELETION_GRACE_MS - DAY_MS,
			),
			reminderSent: false,
		};
		tx.delete(otpRef);
		tx.update(userRef, { scheduledDeletion: schedule, tokensRevokedAt: now });
		// Kept outside the user's recursively deleted subtree; never client writable.
		tx.create(db.collection(AUDIT_COLLECTION).doc(requestId), {
			uid,
			state: "revoking",
			requestedAt: now,
			deleteAt: schedule.deleteAt,
			source: "scheduleAccountDeletion",
			verification: "email_otp",
		});
		return schedule;
	});
	if (!result)
		throw new HttpsError("permission-denied", "Invalid verification code");
	return result;
}

/** Cancellation and the worker's irreversible claim serialize on the user doc. */
export async function cancelDeletion(
	db: Firestore,
	uid: string,
	source: string,
	now = Timestamp.now(),
): Promise<boolean> {
	const ref = db.collection("users").doc(uid);
	const otpRef = ref.collection("otpVerification").doc("deletion");
	return db.runTransaction(async (tx) => {
		// All lifecycle transactions lock the user first, then dependent documents.
		const user = await tx.get(ref);
		const otp = await tx.get(otpRef);
		if (!user.exists) return false;
		const schedule = user.data()?.scheduledDeletion;
		// Keep both reads in the transaction: concurrent OTP/schedule creation must conflict.
		if (schedule == null && !otp.exists && user.data()?.tokensRevokedAt == null)
			return false;
		const auditRef =
			typeof schedule?.requestId === "string" &&
			/^[a-f0-9-]{36}$/.test(schedule.requestId)
				? db.collection(AUDIT_COLLECTION).doc(schedule.requestId)
				: null;
		const audit = auditRef ? await tx.get(auditRef) : null;
		// A sign-in must not race the outstanding Auth side effect. Even a
		// malformed revoking record fails closed until an operator repairs it.
		if (schedule?.state === "revoking") {
			throw new HttpsError(
				"unavailable",
				"Securing your sessions. Please try signing in again shortly.",
				{ reason: "account-deletion-revoking" },
			);
		}
		if (
			schedule?.state === "deleting" &&
			audit?.data()?.uid === uid &&
			audit.data()?.state === "deleting"
		) {
			throw new HttpsError(
				"failed-precondition",
				"[account-deletion-in-progress] Account deletion has already started. Contact support.",
				{ reason: "account-deletion-in-progress" },
			);
		}
		tx.update(ref, {
			scheduledDeletion: FieldValue.delete(),
			tokensRevokedAt: FieldValue.delete(),
			deletionCancelledAt: now,
		});
		// Also invalidates an outstanding OTP, fencing delayed scheduling requests.
		tx.delete(otpRef);
		if (auditRef && audit?.data()?.uid === uid) {
			tx.update(auditRef, {
				state: "cancelled",
				cancelledAt: now,
				cancellationSource: source,
			});
		}
		return schedule != null;
	});
}

/** Shared authorization checks for reminders and destructive claims. */
export function isVerifiedDeletion(
	schedule: DocumentData | undefined,
	proof: DocumentData | undefined,
	uid: string,
): boolean {
	return Boolean(
		schedule?.version === 2 &&
			typeof schedule.requestId === "string" &&
			/^[a-f0-9-]{36}$/.test(schedule.requestId) &&
			proof?.uid === uid &&
			proof.verification === "email_otp" &&
			proof.state === schedule.state &&
			schedule.scheduledAt instanceof Timestamp &&
			schedule.deleteAt instanceof Timestamp &&
			proof.requestedAt instanceof Timestamp &&
			proof.deleteAt instanceof Timestamp &&
			proof.requestedAt.isEqual(schedule.scheduledAt) &&
			proof.deleteAt.isEqual(schedule.deleteAt) &&
			schedule.deleteAt.toMillis() - schedule.scheduledAt.toMillis() >=
				DELETION_GRACE_MS,
	);
}

/** Call only after disabling Auth and revoking refresh tokens successfully. */
export async function recordDeletionAuthInvalidation(
	db: Firestore,
	uid: string,
	requestId: string,
	leaseId: string,
	wasDisabled: boolean,
	now = Timestamp.now(),
): Promise<boolean> {
	return db.runTransaction(async (tx) => {
		const userRef = db.collection("users").doc(uid);
		const auditRef = db.collection(AUDIT_COLLECTION).doc(requestId);
		const user = await tx.get(userRef);
		const audit = await tx.get(auditRef);
		if (user.data()?.scheduledDeletion?.leaseId !== leaseId)
			throw new Error("Deletion lease changed");
		const invalidatedAt = audit.data()?.authInvalidatedAt;
		if (wasDisabled && invalidatedAt instanceof Timestamp)
			return (
				now.toMillis() - invalidatedAt.toMillis() >= DELETION_TOKEN_DRAIN_MS
			);
		tx.update(auditRef, { authInvalidatedAt: now });
		return false;
	});
}

/** A lost/expired lease is an error, never permission to continue deleting. */
export async function renewDeletionLease(
	db: Firestore,
	uid: string,
	leaseId: string,
	now = Timestamp.now(),
) {
	const ref = db.collection("users").doc(uid);
	await db.runTransaction(async (tx) => {
		const schedule = (await tx.get(ref)).data()?.scheduledDeletion;
		if (
			schedule?.state !== "deleting" ||
			schedule.leaseId !== leaseId ||
			!(schedule.leaseUntil instanceof Timestamp) ||
			schedule.leaseUntil.toMillis() <= now.toMillis()
		)
			throw new Error("Deletion lease changed or expired");
		tx.update(ref, {
			"scheduledDeletion.leaseUntil": Timestamp.fromMillis(
				now.toMillis() + LEASE_MS,
			),
		});
	});
}

/** Legacy/unverified markers are held for investigation, never auto-migrated. */
export async function claimDeletion(
	db: Firestore,
	uid: string,
	requestId: string,
	lastSignInMillis: number,
	now = Timestamp.now(),
): Promise<string | null> {
	if (!/^[a-f0-9-]{36}$/.test(requestId)) return null;
	const ref = db.collection("users").doc(uid);
	const auditRef = db.collection(AUDIT_COLLECTION).doc(requestId);
	const leaseId = randomUUID();
	return db.runTransaction(async (tx) => {
		const user = await tx.get(ref);
		const audit = await tx.get(auditRef);
		const schedule = user.data()?.scheduledDeletion;
		const proof = audit.data();
		if (
			!isVerifiedDeletion(schedule, proof, uid) ||
			schedule?.requestId !== requestId ||
			schedule.deleteAt.toMillis() > now.toMillis()
		)
			return null;
		if (schedule.state === "pending" && proof?.state === "pending") {
			// Retain accounts authenticated after the request even if the app never finished startup.
			if (
				!Number.isFinite(lastSignInMillis) ||
				lastSignInMillis >= schedule.scheduledAt.toMillis()
			)
				return null;
		} else if (schedule.state === "deleting" && proof?.state === "deleting") {
			if (
				!(schedule.leaseUntil instanceof Timestamp) ||
				schedule.leaseUntil.toMillis() > now.toMillis()
			)
				return null;
		} else return null;
		tx.update(ref, {
			"scheduledDeletion.state": "deleting",
			"scheduledDeletion.leaseId": leaseId,
			"scheduledDeletion.leaseUntil": Timestamp.fromMillis(
				now.toMillis() + LEASE_MS,
			),
		});
		tx.update(auditRef, { state: "deleting", lastAttemptAt: now });
		return leaseId;
	});
}

export async function finishDeletion(
	db: Firestore,
	uid: string,
	requestId: string,
	leaseId: string,
	adminCollection: string,
) {
	const ref = db.collection("users").doc(uid);
	await db.runTransaction(async (tx) => {
		const user = await tx.get(ref);
		if (user.data()?.scheduledDeletion?.leaseId !== leaseId)
			throw new Error("Deletion lease changed");
		tx.delete(ref);
		tx.delete(db.collection(adminCollection).doc(uid));
		tx.update(db.collection(AUDIT_COLLECTION).doc(requestId), {
			state: "completed",
			completedAt: Timestamp.now(),
		});
	});
}

export async function markDeletionReminderSent(
	db: Firestore,
	uid: string,
	requestId: string,
) {
	const ref = db.collection("users").doc(uid);
	await db.runTransaction(async (tx) => {
		const user = await tx.get(ref);
		const schedule = user.data()?.scheduledDeletion;
		if (schedule?.requestId === requestId && schedule.state === "pending") {
			tx.update(ref, { "scheduledDeletion.reminderSent": true });
		}
	});
}
