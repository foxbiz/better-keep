import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { databaseId, db } from "../config";

/**
 * Triggered when a note document is updated.
 * If the note is marked as deleted or trashed, revokes all active shares for that note.
 */
export default onDocumentUpdated(
	{
		document: "users/{userId}/notes/{noteId}",
		database: databaseId,
		memory: "256MiB",
	},
	async (event) => {
		const beforeData = event.data?.before.data();
		const afterData = event.data?.after.data();

		if (!beforeData || !afterData) {
			return;
		}

		const wasDeleted = beforeData.deleted === true;
		const isDeleted = afterData.deleted === true;
		const wasTrashed = beforeData.trashed === true;
		const isTrashed = afterData.trashed === true;

		// Only act if the note was just deleted or trashed
		const justDeleted = !wasDeleted && isDeleted;
		const justTrashed = !wasTrashed && isTrashed;

		if (!justDeleted && !justTrashed) {
			return;
		}

		const userId = event.params.userId;
		const noteLocalId = afterData.local_id;
		const action = justDeleted ? "deleted" : "trashed";

		console.log(
			`[revokeSharesOnNoteDelete] Note ${noteLocalId} was ${action} by user ${userId}`,
		);

		try {
			// Find all active shares for this note
			const sharesQuery = await db
				.collection("shares")
				.where("owner_uid", "==", userId)
				.where("note_id", "==", String(noteLocalId))
				.where("status", "==", "active")
				.get();

			if (sharesQuery.empty) {
				console.log(
					`[revokeSharesOnNoteDelete] No active shares found for note ${noteLocalId}`,
				);
				return;
			}

			console.log(
				`[revokeSharesOnNoteDelete] Found ${sharesQuery.size} active shares to revoke`,
			);

			const batch = db.batch();
			const now = new Date().toISOString();

			for (const doc of sharesQuery.docs) {
				batch.update(doc.ref, {
					status: "revoked",
					revoked_at: now,
				});
			}

			await batch.commit();
			console.log(
				`[revokeSharesOnNoteDelete] Revoked ${sharesQuery.size} shares for note ${noteLocalId}`,
			);
		} catch (error) {
			console.error(
				`[revokeSharesOnNoteDelete] Error revoking shares for note ${noteLocalId}:`,
				error,
			);
		}
	},
);
