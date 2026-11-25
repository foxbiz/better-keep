import { HttpsError } from "firebase-functions/v2/https";
import { onNonReviewCall } from "../nonReviewCallable";

// Keep the deployed name as a non-mutating tombstone. The app submits the code
// directly to scheduleAccountDeletion, which verifies and consumes it atomically.
// The old separate verifier overwrote OTP fields and raced issuance/cancellation.
export default onNonReviewCall(async () => {
	throw new HttpsError(
		"failed-precondition",
		"Submit the verification code to scheduleAccountDeletion instead.",
	);
});
