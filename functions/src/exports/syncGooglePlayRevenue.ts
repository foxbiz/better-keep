import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue } from "firebase-admin/firestore";
import { ADMIN_METRICS_COLLECTION } from "../adminConfig";
import { db, googlePlayCredentials } from "../config";
import { syncGooglePlayRevenueReports } from "../googlePlayRevenue";

export default onSchedule(
	{
		schedule: "30 4 * * *",
		timeZone: "Etc/UTC",
		secrets: [googlePlayCredentials],
		timeoutSeconds: 540,
	},
	async () => {
		const bucket = process.env.GOOGLE_PLAY_REPORT_BUCKET?.trim();
		if (!bucket) {
			await db
				.collection(ADMIN_METRICS_COLLECTION)
				.doc("current")
				.set(
					{
						"revenueProviderStatus.play_store": {
							status: "misconfigured",
							updatedAt: FieldValue.serverTimestamp(),
						},
					},
					{ merge: true },
				);
			throw new Error("GOOGLE_PLAY_REPORT_BUCKET is not configured");
		}
		const result = await syncGooglePlayRevenueReports({ bucket });
		await db
			.collection(ADMIN_METRICS_COLLECTION)
			.doc("current")
			.set(
				{
					"revenueProviderStatus.play_store": {
						status: "ready",
						reports: result.reports,
						lastImportRows: result.imported,
						updatedAt: FieldValue.serverTimestamp(),
					},
				},
				{ merge: true },
			);
		console.log(
			`Google Play revenue sync imported ${result.imported} rows from ${result.reports} reports`,
		);
	},
);
