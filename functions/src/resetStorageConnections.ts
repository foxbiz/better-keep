/** Retire grants encrypted with the discarded key after verified account reset.
 * Never read/decrypt credentials or delete files in external providers.
 * Kept injectable so reset tests cannot contact a live backend.
 */
export async function resetStorageConnections(
	db: Pick<FirebaseFirestore.Firestore, "batch">,
	user: FirebaseFirestore.DocumentReference,
): Promise<void> {
	const batch = db.batch();
	for (const provider of ["google_drive", "dropbox", "nextcloud", "webdav"]) {
		batch.delete(user.collection("storage_credentials").doc(provider));
		batch.delete(user.collection("storage_connections").doc(provider));
	}
	batch.delete(user.collection("sync_settings").doc("firebase"));
	await batch.commit();
}
