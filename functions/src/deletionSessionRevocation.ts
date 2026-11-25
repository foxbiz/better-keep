import { randomUUID } from "node:crypto";
import {
	FieldValue,
	type Firestore,
	Timestamp,
} from "firebase-admin/firestore";
import { isVerifiedDeletion } from "./accountDeletionLifecycle";

// Only an attempt that has not dispatched Auth may be reclaimed on expiry.
// A dispatched attempt remains fenced until its Auth promise settles; a crashed
// invocation requires operator recovery, not a timeout-based takeover.
export const REVOCATION_LEASE_MS = 10 * 60 * 1000;
export const REVOCATION_TIMEOUT_SECONDS = 300;

export async function revokeDeletionSessions(
	db: Firestore,
	uid: string,
	requestId: string,
	revoke: (uid: string) => Promise<void>,
	clock = () => Timestamp.now(),
): Promise<void> {
	const userRef = db.collection("users").doc(uid);
	const auditRef = db.collection("accountDeletionRequests").doc(requestId);
	const attempt = randomUUID();
	const claimed = await db.runTransaction(async (tx) => {
		const user = await tx.get(userRef);
		const audit = await tx.get(auditRef);
		const schedule = user.data()?.scheduledDeletion;
		const proof = audit.data();
		if (proof?.state !== "revoking") return false; // Duplicate after completion/cancellation.
		if (
			schedule?.requestId !== requestId ||
			!isVerifiedDeletion(schedule, proof, uid)
		) {
			throw new Error("Session revocation lifecycle does not match");
		}
		if (proof.revocationDispatchedAt instanceof Timestamp) {
			throw new Error("Session revocation attempt still in progress");
		}
		const now = clock();
		if (
			proof.revocationLeaseUntil instanceof Timestamp &&
			proof.revocationLeaseUntil.toMillis() > now.toMillis()
		) {
			throw new Error("Session revocation attempt still in progress"); // Eventarc retries.
		}
		tx.update(auditRef, {
			revocationAttempt: attempt,
			revocationLeaseUntil: Timestamp.fromMillis(
				now.toMillis() + REVOCATION_LEASE_MS,
			),
			revocationAttempts: FieldValue.increment(1),
		});
		return true;
	});
	if (!claimed) return;
	// Persist the dispatch fence before calling Auth. Function timeout does not
	// guarantee execution stops, so another invocation must not steal this phase.
	await db.runTransaction(async (tx) => {
		const audit = await tx.get(auditRef);
		const proof = audit.data();
		const now = clock();
		if (
			proof?.state !== "revoking" ||
			proof.revocationAttempt !== attempt ||
			!(proof.revocationLeaseUntil instanceof Timestamp) ||
			proof.revocationLeaseUntil.toMillis() <= now.toMillis()
		) {
			throw new Error("Session revocation attempt changed or expired");
		}
		tx.update(auditRef, { revocationDispatchedAt: now });
	});
	// Never put external Auth effects inside a retryable Firestore transaction.
	try {
		await revoke(uid);

		await db.runTransaction(async (tx) => {
			const user = await tx.get(userRef);
			const audit = await tx.get(auditRef);
			const schedule = user.data()?.scheduledDeletion;
			const proof = audit.data();
			const now = clock();
			if (
				schedule?.requestId !== requestId ||
				!isVerifiedDeletion(schedule, proof, uid) ||
				proof?.state !== "revoking" ||
				proof.revocationAttempt !== attempt ||
				!(proof.revocationDispatchedAt instanceof Timestamp)
			) {
				throw new Error("Session revocation attempt changed");
			}
			tx.update(userRef, { "scheduledDeletion.state": "pending" });
			tx.update(auditRef, {
				state: "pending",
				sessionsRevokedAt: now,
				revocationDispatchedAt: FieldValue.delete(),
				revocationAttempt: FieldValue.delete(),
				revocationLeaseUntil: FieldValue.delete(),
			});
		});
	} catch (error) {
		// Auth has settled, whether it failed or the completion commit failed.
		// This invocation will never call Auth again. Release only this attempt
		// for retry; a lost commit reply may already have allowed cancellation.
		// If this recovery write also fails, retain the fence for operator recovery.
		await db.runTransaction(async (tx) => {
			const audit = await tx.get(auditRef);
			const proof = audit.data();
			if (proof?.state !== "revoking" || proof.revocationAttempt !== attempt)
				return;
			tx.update(auditRef, {
				revocationDispatchedAt: FieldValue.delete(),
				revocationLeaseUntil: clock(),
			});
		});
		throw error;
	}
}
