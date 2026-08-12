import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { databaseId } from "../config";
import { syncAdminUserIndex } from "../adminUserIndex";

export default onDocumentWritten(
	{ document: "users/{userId}/subscription/status", database: databaseId },
	async (event) => {
		await syncAdminUserIndex(event.params.userId);
	},
);
