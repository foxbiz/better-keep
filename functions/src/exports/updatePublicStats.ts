import { onSchedule } from "firebase-functions/v2/scheduler";
import { auth, db } from "../config";

/**
 * Scheduled function to update public statistics.
 * Runs every 6 hours to count Firebase Auth users and update a public stats document.
 * The count is rounded for privacy (e.g., 527 → "500+").
 */
export default onSchedule(
	{
		schedule: "0 */6 * * *", // Every 6 hours (at minute 0)
		timeoutSeconds: 120, // 2 minutes max
	},
	async () => {
		console.log("Updating public statistics...");

		try {
			// Count all users via Firebase Auth
			let userCount = 0;
			let pageToken: string | undefined;

			do {
				const result = await auth.listUsers(1000, pageToken);
				userCount += result.users.length;
				pageToken = result.pageToken;
			} while (pageToken);

			console.log(`Total users found: ${userCount}`);

			// Round for privacy based on count size
			let displayCount: string;
			if (userCount < 10) {
				displayCount = userCount.toString();
			} else if (userCount < 100) {
				// Round to nearest 10
				const rounded = Math.floor(userCount / 10) * 10;
				displayCount = `${rounded}+`;
			} else if (userCount < 1000) {
				// Round to nearest 50
				const rounded = Math.floor(userCount / 50) * 50;
				displayCount = `${rounded}+`;
			} else {
				// Round to nearest 100
				const rounded = Math.floor(userCount / 100) * 100;
				displayCount = `${rounded}+`;
			}

			// Write to public stats document
			await db.collection("stats").doc("public").set({
				userCount: displayCount,
				userCountExact: userCount, // For internal analytics (not exposed publicly)
				updatedAt: new Date(),
			});

			console.log(`Public stats updated: ${displayCount} users`);
		} catch (error) {
			console.error("Failed to update public stats:", error);
			throw error;
		}
	},
);
