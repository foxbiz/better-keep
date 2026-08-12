import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { ADMIN_REVENUE_EVENT_COLLECTION } from "../adminConfig";
import { databaseId } from "../config";
import { processRevenueEvent } from "../revenueOutbox";

export default onDocumentCreated(
	{
		document: `${ADMIN_REVENUE_EVENT_COLLECTION}/{eventId}`,
		database: databaseId,
		retry: true,
	},
	async (event) => {
		await processRevenueEvent(event.params.eventId);
	},
);
