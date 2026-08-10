import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { ADMIN_REVENUE_EVENT_COLLECTION } from "../adminConfig";
import { db } from "../config";
import { processRevenueEvent } from "../revenueOutbox";

export default onSchedule(
	{ schedule: "every 10 minutes", timeZone: "UTC" },
	async () => {
		const now = Timestamp.now();
		const collection = db.collection(ADMIN_REVENUE_EVENT_COLLECTION);
		const [pending, failed, abandoned] = await Promise.all([
			collection.where("status", "==", "pending").limit(100).get(),
			collection
				.where("status", "==", "failed")
				.where("nextAttemptAt", "<=", now)
				.orderBy("nextAttemptAt")
				.limit(100)
				.get(),
			collection
				.where("status", "==", "processing")
				.where("leaseUntil", "<=", now)
				.orderBy("leaseUntil")
				.limit(100)
				.get(),
		]);
		const eventIds = new Set(
			[...pending.docs, ...failed.docs, ...abandoned.docs].map(
				(document) => document.id,
			),
		);
		for (const eventId of eventIds) {
			await processRevenueEvent(eventId).catch((error) => {
				console.error(`Scheduled revenue retry failed for ${eventId}:`, error);
			});
		}
	},
);
