import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { db } from "../config";

/**
 * Scheduled function that runs daily at 3:00 AM UTC
 * Cleans up pending device requests that are older than 24 hours.
 * This prevents clutter from abandoned device approval requests.
 */
export default onSchedule(
	{
		schedule: "0 3 * * *", // Cron: every day at 3:00 AM UTC
		timeZone: "UTC",
	},
	async () => {
		const now = Timestamp.now();
		// Devices pending for more than 24 hours are considered expired
		const expirationThreshold = Timestamp.fromMillis(
			now.toMillis() - 24 * 60 * 60 * 1000, // 24 hours ago
		);

		console.log(
			`Cleaning up expired pending devices at ${now.toDate().toISOString()}`,
		);
		console.log(
			`Expiration threshold: ${expirationThreshold.toDate().toISOString()}`,
		);

		const results = {
			usersProcessed: 0,
			devicesDeleted: 0,
			errors: 0,
		};

		try {
			// Get all users
			const usersSnapshot = await db.collection("users").get();

			for (const userDoc of usersSnapshot.docs) {
				const userId = userDoc.id;

				try {
					// Get pending devices for this user
					const devicesRef = userDoc.ref.collection("devices");
					const pendingDevicesSnapshot = await devicesRef
						.where("status", "==", "pending")
						.get();

					if (pendingDevicesSnapshot.empty) continue;

					results.usersProcessed++;
					const batch = db.batch();
					let deletedCount = 0;

					for (const deviceDoc of pendingDevicesSnapshot.docs) {
						const data = deviceDoc.data();
						const createdAt = data.created_at;

						if (!createdAt) {
							// No created_at field - delete it (malformed data)
							batch.delete(deviceDoc.ref);
							deletedCount++;
							continue;
						}

						// Parse the ISO string date
						const createdDate = new Date(createdAt);
						const createdTimestamp = Timestamp.fromDate(createdDate);

						// Check if device is older than 24 hours
						if (createdTimestamp.toMillis() < expirationThreshold.toMillis()) {
							batch.delete(deviceDoc.ref);
							deletedCount++;
						}
					}

					if (deletedCount > 0) {
						await batch.commit();
						results.devicesDeleted += deletedCount;
						console.log(
							`Deleted ${deletedCount} expired pending devices for user ${userId}`,
						);
					}
				} catch (userError) {
					results.errors++;
					console.error(`Error processing user ${userId}:`, userError);
				}
			}

			console.log(
				`Cleanup complete: processed ${results.usersProcessed} users, ` +
					`deleted ${results.devicesDeleted} expired pending devices, ` +
					`${results.errors} errors`,
			);
		} catch (error) {
			console.error("Error during pending device cleanup:", error);
		}
	},
);
