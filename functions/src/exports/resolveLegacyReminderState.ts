import { FieldValue } from "firebase-admin/firestore";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { databaseId, db } from "../config";
import {
	detectLegacyReminderTransition,
	resolveLegacyReminderTransition,
} from "../reminderStateResolver";

export default onDocumentUpdated(
	{
		document: "users/{userId}/notes/{noteId}",
		database: databaseId,
		memory: "256MiB",
	},
	async (event) => {
		const before = event.data?.before.data();
		const after = event.data?.after.data();
		if (!before || !after) return;

		const transition = detectLegacyReminderTransition(before, after);
		if (!transition) return;

		const noteRef = event.data?.after.ref;
		if (!noteRef) return;
		const reconciled = await db.runTransaction(async (transaction) => {
			const currentSnapshot = await transaction.get(noteRef);
			const current = currentSnapshot.data();
			if (!current) return false;
			const resolution = resolveLegacyReminderTransition(
				transition,
				current,
				event.id,
			);
			if (!resolution) return false;
			transaction.update(noteRef, {
				reminder_v2: FieldValue.delete(),
				reminder_state_v3: resolution.state,
			});
			return true;
		});
		if (reconciled) {
			console.log(
				`[resolveLegacyReminderState] Reconciled legacy reminder write for user ${event.params.userId}, note ${event.params.noteId}`,
			);
		}
	},
);
