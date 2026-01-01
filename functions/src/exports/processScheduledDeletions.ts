import type * as admin from "firebase-admin";
import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
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
	},
);

/**
 * Deletes all user data from Firestore, Storage, and Firebase Auth
 */
async function deleteUserCompletely(userId: string): Promise<void> {
	console.log(`Starting complete deletion for user: ${userId}`);

	const userRef = db.collection("users").doc(userId);

	// 1. Delete all known subcollections
	const subcollections = await userRef.listCollections();

	for (const subcollection of subcollections) {
		console.log(`  Deleting subcollection: ${subcollection.id}`);
		await deleteCollection(subcollection);
	}

	// 2. Delete user's files from Cloud Storage
	try {
		const bucket = storage.bucket();
		const [files] = await bucket.getFiles({ prefix: `users/${userId}/` });

		if (files.length > 0) {
			console.log(`  Deleting ${files.length} files from Storage`);
			for (const file of files) {
				await file.delete();
			}
		}
	} catch (error) {
		// Storage errors shouldn't stop the deletion process
		console.warn(`  Warning: Storage deletion issue for ${userId}:`, error);
	}

	// 3. Delete the user document itself
	console.log("  Deleting user document");
	await userRef.delete();

	// 4. Delete the Firebase Auth user
	try {
		await auth.deleteUser(userId);
		console.log("  Deleted Auth user");
	} catch (error: unknown) {
		// User might already be deleted from Auth, or never existed
		const authError = error as { code?: string };
		if (authError.code === "auth/user-not-found") {
			console.log("  Auth user already deleted or not found");
		} else {
			console.warn(`  Warning: Auth deletion issue for ${userId}:`, error);
		}
	}

	console.log(`  Complete deletion finished for user: ${userId}`);
}

/**
 * Recursively deletes all documents in a Firestore collection
 */
async function deleteCollection(
	collectionRef: admin.firestore.CollectionReference,
): Promise<void> {
	const batchSize = 500;

	const deleteQueryBatch = async (): Promise<void> => {
		const snapshot = await collectionRef.limit(batchSize).get();

		if (snapshot.empty) {
			return;
		}

		const batch = db.batch();
		for (const doc of snapshot.docs) {
			batch.delete(doc.ref);
		}
		await batch.commit();

		// If we deleted a full batch, there might be more documents
		if (snapshot.size === batchSize) {
			await deleteQueryBatch();
		}
	};

	await deleteQueryBatch();
}
