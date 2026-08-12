import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { ADMIN_USER_COLLECTION } from "../adminConfig";
import { auth, db, storage } from "../config";

/**
 * Scheduled function that runs daily at 2:00 AM UTC
 * Processes users who have scheduled account deletion and whose 30-day
 * grace period has expired.
 */
export default onSchedule(
	{
		schedule: "0 2 * * *", // Cron: every day at 2:00 AM UTC
		timeZone: "UTC",
		retryCount: 5,
		minBackoffSeconds: 60,
		maxBackoffSeconds: 3600,
	},
	async () => {
		const now = Timestamp.now();

		console.log(
			`Processing scheduled deletions at ${now.toDate().toISOString()}`,
		);

		// Query users whose deletion time has passed
		const snapshot = await db
			.collection("users")
			.where("scheduledDeletion.deleteAt", "<=", now)
			.get();

		console.log(`Found ${snapshot.size} users scheduled for deletion`);

		const results = {
			processed: 0,
			succeeded: 0,
			failed: 0,
			errors: [] as string[],
		};

		for (const doc of snapshot.docs) {
			const userId = doc.id;
			results.processed++;

			try {
				await deleteUserCompletely(userId);
				results.succeeded++;
				console.log(`✓ Successfully deleted user: ${userId}`);
			} catch (error) {
				results.failed++;
				const errorMsg = `Failed to delete user ${userId}: ${error}`;
				results.errors.push(errorMsg);
				console.error(`✗ ${errorMsg}`);
			}
		}

		console.log(
			`Deletion complete: ${results.succeeded}/${results.processed} succeeded, ` +
				`${results.failed} failed`,
		);
		if (results.failed > 0) {
			throw new Error(
				`${results.failed} scheduled account deletion(s) failed and remain queued`,
			);
		}
	},
);

/**
 * Deletes all user data from Firestore, Storage, and Firebase Auth
 */
async function deleteUserCompletely(userId: string): Promise<void> {
	console.log(`Starting complete deletion for user: ${userId}`);
	await executeUserDeletion(userId, {
		deleteSubcollections: async () => {
			const userRef = db.collection("users").doc(userId);
			const subcollections = await userRef.listCollections();
			for (const subcollection of subcollections) {
				console.log(`  Deleting subcollection: ${subcollection.id}`);
				await db.recursiveDelete(subcollection);
			}
		},
		deleteStorage: async () => {
			const [files] = await storage
				.bucket()
				.getFiles({ prefix: `users/${userId}/` });
			console.log(`  Deleting ${files.length} files from Storage`);
			for (const file of files) {
				try {
					await file.delete();
				} catch (error) {
					if (!isNotFoundError(error)) throw error;
				}
			}
		},
		deleteAuthUser: async () => {
			try {
				await auth.deleteUser(userId);
				console.log("  Deleted Auth user");
			} catch (error) {
				if (!isNotFoundError(error)) throw error;
				console.log("  Auth user already deleted or not found");
			}
		},
		deleteFirestoreRoots: async () => {
			const batch = db.batch();
			batch.delete(db.collection("users").doc(userId));
			batch.delete(db.collection(ADMIN_USER_COLLECTION).doc(userId));
			await batch.commit();
		},
	});

	console.log(`  Complete deletion finished for user: ${userId}`);
}

export interface UserDeletionOperations {
	deleteSubcollections: () => Promise<void>;
	deleteStorage: () => Promise<void>;
	deleteAuthUser: () => Promise<void>;
	deleteFirestoreRoots: () => Promise<void>;
}

export function isNotFoundError(error: unknown): boolean {
	const candidate = error as { code?: string | number };
	return (
		candidate?.code === "auth/user-not-found" ||
		candidate?.code === "storage/object-not-found" ||
		candidate?.code === 404
	);
}

export async function executeUserDeletion(
	_userId: string,
	operations: UserDeletionOperations,
): Promise<void> {
	await operations.deleteSubcollections();
	await operations.deleteStorage();
	await operations.deleteAuthUser();
	await operations.deleteFirestoreRoots();
}
