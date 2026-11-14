import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { auth, databaseId, db } from "../config";
import {
	REVOCATION_TIMEOUT_SECONDS,
	revokeDeletionSessions,
} from "../deletionSessionRevocation";

export default onDocumentCreated(
	{
		document: "accountDeletionRequests/{requestId}",
		database: databaseId,
		retry: true,
		timeoutSeconds: REVOCATION_TIMEOUT_SECONDS,
	},
	async (event) => {
		const data = event.data?.data();
		if (data?.state !== "revoking" || typeof data.uid !== "string") return;
		await revokeDeletionSessions(
			db,
			data.uid,
			event.params.requestId,
			async (uid) => {
				try {
					await auth.revokeRefreshTokens(uid);
				} catch (error) {
					// A missing Auth account has no sessions. Still finish the durable phase.
					if ((error as { code?: string })?.code !== "auth/user-not-found")
						throw error;
				}
			},
		);
	},
);
