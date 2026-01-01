import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { db } from "../config";

/**
 * Cleanup failed/abandoned Razorpay payments
 * Runs daily at 3 AM
 */
export default onSchedule(
	{
		schedule: "0 3 * * *", // Daily at 3 AM
		timeZone: "Asia/Kolkata",
	},
	async () => {
		console.log("Starting cleanup of failed Razorpay payments");

		try {
			// Find payments older than 24 hours that are still in 'created' status
			const cutoff = new Date();
			cutoff.setHours(cutoff.getHours() - 24);

			const failedPayments = await db
				.collection("payments")
				.where("status", "==", "created")
				.where("createdAt", "<", Timestamp.fromDate(cutoff))
				.get();

			console.log(
				`Found ${failedPayments.size} failed/abandoned payments to cleanup`,
			);

			const batch = db.batch();
			for (const doc of failedPayments.docs) {
				batch.delete(doc.ref);
			}

			await batch.commit();
			console.log("Cleanup completed");
		} catch (error) {
			console.error("Error cleaning up failed payments:", error);
		}
	},
);
