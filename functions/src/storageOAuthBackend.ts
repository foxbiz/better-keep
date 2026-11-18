import { HttpsError, onRequest } from "firebase-functions/v2/https";
import { onNonReviewCall } from "./nonReviewCallable";

// Retired routes must remain explicit during rollout: old clients must never
// send new grants through a backend token exchange or a shared-key vault.
const retired = () => {
	throw new HttpsError(
		"failed-precondition",
		"Update Better Keep and reconnect storage",
	);
};
export const prepareStorageOAuth = onNonReviewCall(retired);
export const completeStorageOAuth = onNonReviewCall(retired);
export const cancelStorageOAuth = onNonReviewCall(retired);
const retiredRoute = () =>
	onRequest((_request, response) => {
		response.set("Cache-Control", "no-store");
		response
			.status(410)
			.type("text/plain")
			.send("Update Better Keep and reconnect storage from the app.");
	});
export const storageOAuthStart = retiredRoute();
export const storageOAuthCallback = retiredRoute();
