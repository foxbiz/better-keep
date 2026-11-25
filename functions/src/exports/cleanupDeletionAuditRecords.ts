import { onSchedule } from "firebase-functions/v2/scheduler";
import { db } from "../config";
import { cleanupDeletionAudits } from "../deletionAuditRetention";

export default onSchedule(
	{
		schedule: "0 4 * * *",
		timeZone: "UTC",
		retryCount: 3,
		maxInstances: 1,
		concurrency: 1,
		timeoutSeconds: 540,
	},
	async () => {
		// Aggregate counts only: no user or request identifiers in retention logs.
		console.log(
			"Deletion audit cleanup complete",
			await cleanupDeletionAudits(db),
		);
	},
);
