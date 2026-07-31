import { FieldValue } from "firebase-admin/firestore";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { databaseId, db } from "./config";

export const syncCommittedAtField = "sync_committed_at";

type TimestampParts = {
	seconds: number;
	nanoseconds: number;
};

function timestampParts(value: unknown): TimestampParts | null {
	if (typeof value !== "object" || value === null) return null;

	const candidate = value as Partial<TimestampParts>;
	if (
		typeof candidate.seconds !== "number" ||
		typeof candidate.nanoseconds !== "number"
	) {
		return null;
	}

	return {
		seconds: candidate.seconds,
		nanoseconds: candidate.nanoseconds,
	};
}

/**
 * Legacy clients either omit the commit marker or preserve the marker from
 * the previous version of a document. New clients replace it with a server
 * timestamp on every mutation.
 */
export function needsSyncCommitStamp(
	beforeValue: unknown,
	afterValue: unknown,
): boolean {
	const after = timestampParts(afterValue);
	if (after === null) return true;

	const before = timestampParts(beforeValue);
	if (before === null) return false;

	return (
		before.seconds === after.seconds &&
		before.nanoseconds === after.nanoseconds
	);
}

function markerStillMatchesObserved(
	observedValue: unknown,
	currentValue: unknown,
): boolean {
	const observed = timestampParts(observedValue);
	const current = timestampParts(currentValue);
	if (observed === null || current === null) {
		return observed === null && current === null;
	}
	return (
		observed.seconds === current.seconds &&
		observed.nanoseconds === current.nanoseconds
	);
}

export function createSyncCommitStampTrigger(document: string) {
	return onDocumentWritten(
		{
			document,
			database: databaseId,
			memory: "256MiB",
		},
		async (event) => {
			const afterSnapshot = event.data?.after;
			if (!afterSnapshot?.exists) return;

			const beforeData = event.data?.before.data();
			const afterData = afterSnapshot.data();
			if (
				!afterData ||
				!needsSyncCommitStamp(
					beforeData?.[syncCommittedAtField],
					afterData[syncCommittedAtField],
				)
			) {
				return;
			}

			const observedMarker = afterData[syncCommittedAtField];
			await db.runTransaction(async (transaction) => {
				const currentSnapshot = await transaction.get(afterSnapshot.ref);
				const currentData = currentSnapshot.data();
				if (
					!currentData ||
					!markerStillMatchesObserved(
						observedMarker,
						currentData[syncCommittedAtField],
					)
				) {
					return;
				}

				transaction.update(afterSnapshot.ref, {
					[syncCommittedAtField]: FieldValue.serverTimestamp(),
				});
			});
		},
	);
}
