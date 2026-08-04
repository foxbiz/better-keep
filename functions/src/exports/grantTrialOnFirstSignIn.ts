import { beforeUserSignedIn, HttpsError } from "firebase-functions/v2/identity";
import { emailPassword } from "../config";
import {
	authorizeNativeAccountLink,
	newNativeProviderLink,
} from "../nativeAccountLinkPolicy";
import { isAllowedReviewSignIn } from "../reviewAccess";
import { grantTrialIfEligible } from "../trialGrant";

/**
 * Grant predefined days of Pro trial to new users on their first successful sign-in.
 * Using beforeUserSignedIn instead of beforeUserCreated to ensure the trial
 * is only granted after a successful sign-in, preventing orphaned trials
 * when sign-in fails after user creation.
 *
 * Trial is only granted once per email (tracked via Firestore trialUsage collection).
 * Also ensures user document exists and sends welcome email with trial info.
 */
export default beforeUserSignedIn(
	{
		secrets: [emailPassword],
		// Note: minInstances removed to save cost. Cold starts may occasionally
		// cause timeouts for Google sign-in, but OAuth providers (Facebook, GitHub,
		// Twitter) now grant trials directly in the OAuth callback.
		// If you experience cold start issues with Google sign-in, add: minInstances: 1
	},
	async (event) => {
		const user = event.data;
		if (!user) {
			console.error("Sign-in blocking event is missing user data", {
				eventId: event.eventId,
				eventType: event.eventType,
			});
			throw new HttpsError(
				"internal",
				"Missing user data for sign-in authorization",
			);
		}

		if (!isAllowedReviewSignIn(user, event.eventType)) {
			throw new HttpsError(
				"permission-denied",
				"The managed review account only supports password sign-in",
			);
		}

		const nativeLinkProvider = newNativeProviderLink(event);
		if (nativeLinkProvider) {
			try {
				await authorizeNativeAccountLink(event, nativeLinkProvider);
			} catch (error) {
				console.error("Native account-link authorization rejected", {
					provider: nativeLinkProvider,
					error: error instanceof Error ? error.message : "unknown",
				});
				throw new HttpsError(
					"permission-denied",
					"Verify the account-link code before linking this provider",
				);
			}
		}

		try {
			return await grantTrialIfEligible({
				user,
				persistCustomClaims: false,
			});
		} catch (error) {
			console.error(`Error granting trial: ${error}`);
			// Don't block sign-in on error
			return {};
		}
	},
);
