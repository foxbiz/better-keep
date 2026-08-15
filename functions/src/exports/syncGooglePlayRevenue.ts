import { onSchedule } from "firebase-functions/v2/scheduler";
import { setRevenueProviderStatus } from "../adminMetrics";
import { googlePlayCredentials } from "../config";
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
			await setRevenueProviderStatus("play_store", {
				status: "misconfigured",
			});
			throw new Error("GOOGLE_PLAY_REPORT_BUCKET is not configured");
		}
		const result = await syncGooglePlayRevenueReports({ bucket });
		await setRevenueProviderStatus("play_store", {
			status: "ready",
			reports: result.reports,
			lastImportRows: result.imported,
		});
		console.log(
			`Google Play revenue sync imported ${result.imported} rows from ${result.reports} reports`,
		);
	},
);
