import type {
	DocumentSnapshot,
	Firestore,
	Transaction,
} from "firebase-admin/firestore";
import { StorageConnectionError } from "./storageConnectionSecurity";

export function requireActiveStorageAccount(user: DocumentSnapshot): void {
	if (!user.exists || user.data()?.scheduledDeletion != null) {
		throw new StorageConnectionError("denied");
	}
}

/** Read in the same transaction as a credential write, so deletion wins races. */
export async function requireStorageAccountTransaction(
	db: Firestore,
	transaction: Transaction,
	uid: string,
): Promise<void> {
	requireActiveStorageAccount(
		await transaction.get(db.collection("users").doc(uid)),
	);
}

/** OAuth slots are top-level documents, outside recursive user cleanup. */
export async function deleteStorageOAuthSessions(
	db: Firestore,
	uid: string,
): Promise<void> {
	while (true) {
		const sessions = await db
			.collection("storageOAuthSessions")
			.where("context.uid", "==", uid)
			.limit(100)
			.get();
		if (sessions.empty) {
			await db.collection("oauth_exchange_limits").doc(uid).delete();
			return;
		}
		const batch = db.batch();
		for (const session of sessions.docs) batch.delete(session.ref);
		await batch.commit();
	}
}
