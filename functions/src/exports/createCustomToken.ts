import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth } from '../config';

/**
 * Creates a custom token for a user who authenticated via web OAuth
 * This allows the mobile app to sign in after web-based OAuth
 */
export default onCall(async (request: CallableRequest) => {
  // User must be authenticated (they just signed in via web OAuth)
  if (!request.auth) {
    throw new HttpsError(
      "unauthenticated",
      "User must be signed in to get a custom token",
    );
  }

  const uid = request.auth.uid;

  try {
    // Create a custom token for this user
    const customToken = await auth.createCustomToken(uid);

    return { token: customToken };
  } catch (error) {
    console.error("Error creating custom token:", error);
    throw new HttpsError("internal", "Failed to create authentication token");
  }
});