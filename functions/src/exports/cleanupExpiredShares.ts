import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { onSchedule } from "firebase-functions/v2/scheduler";

// Initialize Firebase Admin if not already initialized
if (getApps().length === 0) {
	initializeApp();
}

const db = getFirestore();
const storage = getStorage();

/**
 * Delete all attachment files for a share from Firebase Storage
 */
async function deleteShareAttachments(
	ownerUid: string,
	shareId: string,
	attachmentPaths: string[] | undefined,
): Promise<void> {
	if (!attachmentPaths || attachmentPaths.length === 0) {
		return;
	}

	const bucket = storage.bucket();

	for (const path of attachmentPaths) {
		try {
			await bucket.file(path).delete();
			console.log(`[cleanupExpiredShares] Deleted attachment: ${path}`);
		} catch (error) {
			// File might not exist, continue with others
			console.log(`[cleanupExpiredShares] Failed to delete ${path}:`, error);
		}
	}

	// Also try to clean up the folder (new path structure includes userId)
	try {
		const [files] = await bucket.getFiles({
			prefix: `shares/${ownerUid}/${shareId}/attachments/`,
		});
		for (const file of files) {
			await file.delete();
		}
	} catch (error) {
		// Folder might be empty or not exist - this is expected
		console.log(`[cleanupExpiredShares] Folder cleanup note: ${error}`);
	}
}

/**
 * Scheduled function to clean up expired share links.
 * Runs every hour to mark expired shares as expired.
 */
export default onSchedule(
	{
		schedule: "every 1 hours",
		timeZone: "UTC",
		memory: "256MiB",
	},
	async () => {
		const now = new Date();
		const nowIso = now.toISOString();

		console.log(`[cleanupExpiredShares] Starting cleanup at ${nowIso}`);

		try {
			// Find all active shares that have expired
			const expiredShares = await db
				.collection("shares")
				.where("status", "==", "active")
				.where("expires_at", "<=", nowIso)
				.get();

			if (expiredShares.empty) {
				console.log("[cleanupExpiredShares] No expired shares found");
				return;
			}

			console.log(
				`[cleanupExpiredShares] Found ${expiredShares.size} expired shares`,
			);

			// Batch update to mark as expired
			let batch = db.batch();
			let count = 0;

			for (const doc of expiredShares.docs) {
				batch.update(doc.ref, {
					status: "expired",
				});
				count++;

				// Firestore batch limit is 500 operations
				if (count >= 450) {
					await batch.commit();
					console.log(`[cleanupExpiredShares] Committed batch of ${count}`);
					count = 0;
					batch = db.batch(); // Create new batch after commit
				}
			}

			// Commit remaining
			if (count > 0) {
				await batch.commit();
				console.log(`[cleanupExpiredShares] Committed final batch of ${count}`);
			}

			console.log(
				`[cleanupExpiredShares] Successfully marked ${expiredShares.size} shares as expired`,
			);

			// Optional: Delete very old expired shares (older than 30 days)
			const thirtyDaysAgo = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
			const oldShares = await db
				.collection("shares")
				.where("status", "in", ["expired", "revoked"])
				.where("expires_at", "<=", thirtyDaysAgo.toISOString())
				.limit(100) // Process in smaller batches
				.get();

			if (!oldShares.empty) {
				console.log(
					`[cleanupExpiredShares] Deleting ${oldShares.size} old shares`,
				);

				for (const doc of oldShares.docs) {
					const shareData = doc.data();

					// Delete attachment files from storage (pass ownerUid for new path structure)
					await deleteShareAttachments(
						shareData.owner_uid,
						doc.id,
						shareData.attachment_paths,
					);

					// Delete all requests for this share
					const requests = await doc.ref.collection("requests").get();
					const deleteBatch = db.batch();
					for (const request of requests.docs) {
						deleteBatch.delete(request.ref);
					}
					deleteBatch.delete(doc.ref);
					await deleteBatch.commit();
				}

				console.log(
					`[cleanupExpiredShares] Deleted ${oldShares.size} old shares with attachments`,
				);
			}
		} catch (error) {
			console.error("[cleanupExpiredShares] Error:", error);
			throw error;
		}
	},
);
