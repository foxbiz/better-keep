import {
	type DocumentData,
	type DocumentReference,
	FieldPath,
	type Firestore,
	Timestamp,
} from "firebase-admin/firestore";

export const DELETION_AUDIT_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;
const SCAN_BUDGET_MS = 480_000;
const terminalTimestamps = {
	completed: "completedAt",
	cancelled: "cancelledAt",
} as const;
type TerminalState = keyof typeof terminalTimestamps;

export function isDeletionAuditExpired(
	data: DocumentData | undefined,
	state: TerminalState,
	now: Timestamp,
): boolean {
	const terminalAt = data?.[terminalTimestamps[state]];
	return (
		data?.state === state &&
		// Missing/malformed holds preserve pre-policy records and incident evidence.
		data.retentionHold === false &&
		terminalAt instanceof Timestamp &&
		terminalAt.toMillis() <= now.toMillis() - DELETION_AUDIT_RETENTION_MS
	);
}

export async function deleteExpiredDeletionAudit(
	db: Firestore,
	ref: DocumentReference,
	uid: unknown,
	state: TerminalState,
	now: Timestamp,
): Promise<boolean> {
	if (typeof uid !== "string" || !uid || uid.includes("/")) return false;
	return db.runTransaction(async (tx) => {
		// Use the same user-first lock order as cancellation and the deletion worker.
		const user = await tx.get(db.collection("users").doc(uid));
		const audit = await tx.get(ref);
		const data = audit.data();
		if (
			data?.uid !== uid ||
			!isDeletionAuditExpired(data, state, now) ||
			user.data()?.scheduledDeletion?.requestId === ref.id
		) {
			return false;
		}
		tx.delete(ref);
		return true;
	});
}

/** Bounded, paginated scans; held and pre-policy records never enter the query. */
export async function cleanupDeletionAudits(
	db: Firestore,
	now = Timestamp.now(),
	clock = Date.now,
) {
	const stopAt = clock() + SCAN_BUDGET_MS;
	const cutoff = Timestamp.fromMillis(
		now.toMillis() - DELETION_AUDIT_RETENTION_MS,
	);
	const counts = {
		scanned: 0,
		deleted: 0,
		skipped: 0,
		timeBudgetExhausted: false,
	};
	for (const state of ["completed", "cancelled"] as const) {
		if (clock() >= stopAt) return { ...counts, timeBudgetExhausted: true };
		const field = terminalTimestamps[state];
		const checkpoint = db
			.collection("accountDeletionWorker")
			.doc(`auditRetention_${state}`);
		const cursor = (await checkpoint.get()).data();
		let query = db
			.collection("accountDeletionRequests")
			.where("state", "==", state)
			.where("retentionHold", "==", false)
			.where(field, "<=", cutoff)
			.orderBy(field)
			.orderBy(FieldPath.documentId())
			.limit(100);
		if (
			cursor?.terminalAt instanceof Timestamp &&
			typeof cursor.requestId === "string" &&
			cursor.requestId.length > 0 &&
			!cursor.requestId.includes("/")
		) {
			query = query.startAfter(cursor.terminalAt, cursor.requestId);
		}
		// Bound record count as well as elapsed time; in-flight reads/transactions
		// may outlast the budget, so leave headroom before the function timeout.
		for (let page = 0; page < 5; page++) {
			if (clock() >= stopAt) return { ...counts, timeBudgetExhausted: true };
			const snapshot = await query.get();
			if (snapshot.empty) {
				await checkpoint.delete(); // Wrap on the next run to revisit skipped records.
				break;
			}
			let lastProcessed: (typeof snapshot.docs)[number] | undefined;
			for (const doc of snapshot.docs) {
				if (clock() >= stopAt) {
					// A partial page must resume after its last processed record, not
					// after the page's end or from the same slow/skipped prefix.
					if (lastProcessed) {
						await checkpoint.set({
							terminalAt: lastProcessed.get(field),
							requestId: lastProcessed.id,
						});
					}
					return { ...counts, timeBudgetExhausted: true };
				}
				counts.scanned++;
				if (
					await deleteExpiredDeletionAudit(
						db,
						doc.ref,
						doc.data().uid,
						state,
						now,
					)
				) {
					counts.deleted++;
				} else {
					counts.skipped++;
				}
				lastProcessed = doc;
			}
			if (snapshot.size < 100) {
				await checkpoint.delete();
				break;
			}
			const last = snapshot.docs[snapshot.docs.length - 1];
			// Persist after each completed page, including pages containing only skips.
			// Values remain usable even if the boundary audit was deleted above.
			await checkpoint.set({ terminalAt: last.get(field), requestId: last.id });
			query = query.startAfter(last);
		}
	}
	return counts;
}
