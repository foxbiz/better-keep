import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { syncAdminUserIndex } from "../adminUserIndex";
import { databaseId } from "../config";

export default onDocumentWritten(
	{ document: "users/{userId}/subscription/status", database: databaseId },
	async (event) => {
		await syncAdminUserIndex(event.params.userId);
	},
);
