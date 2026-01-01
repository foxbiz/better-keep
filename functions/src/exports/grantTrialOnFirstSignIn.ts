import { Timestamp } from "firebase-admin/firestore";
import { beforeUserSignedIn } from "firebase-functions/v2/identity";
import {
	DEBUG_TRIAL_MINUTES,
	db,
	emailPassword,
	TRIAL_DAYS,
	TRIAL_ENABLED,
} from "../config";
import { sendTrialWelcomeEmail } from "../utils";

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
		// Check if trial is enabled via environment variable
		if (!TRIAL_ENABLED) {
			return {};
		}

		const user = event.data;
		const userId = user.uid;
		// Handle null/undefined email gracefully (Twitter users may not have email)
		const email = user.email?.trim()?.toLowerCase() || null;
		const emailKey = email || `no-email-${userId}`;

		console.log(`User signing in: ${userId} (${email || "no email"})`);

		try {
			// Fast path: Check subscription and trial usage in parallel
			const userRef = db.collection("users").doc(userId);
			const subscriptionRef = userRef.collection("subscription").doc("status");
			const trialRef = db.collection("trialUsage").doc(emailKey);

			const [existingSubscription, trialDoc] = await Promise.all([
				subscriptionRef.get(),
				trialRef.get(),
			]);

			// Already has subscription - return immediately (most common case for returning users)
			if (existingSubscription.exists) {
				console.log(`User ${userId} already has subscription`);
				return {};
			}

			// Email already used trial - return immediately
			if (trialDoc.exists) {
				console.log(`Email ${email} already used trial`);
				return {};
			}

			// New user needs trial - calculate expiry
			const trialExpiresAt = new Date();
			if (DEBUG_TRIAL_MINUTES !== null) {
				trialExpiresAt.setMinutes(
					trialExpiresAt.getMinutes() + DEBUG_TRIAL_MINUTES,
				);
			} else {
				trialExpiresAt.setDate(trialExpiresAt.getDate() + TRIAL_DAYS);
			}

			console.log(
				`Granting trial to ${userId}, expires ${trialExpiresAt.toISOString()}`,
			);

			// Write operations in parallel for speed
			await Promise.all([
				// Mark trial as used (by email if available, else by userId)
				trialRef.set({
					userId: userId,
					email: email || "none",
					trialStartedAt: Timestamp.now(),
					trialExpiresAt: Timestamp.fromDate(trialExpiresAt),
					createdAt: Timestamp.now(),
				}),
				// Create/update user document
				userRef.set(
					{
						email: email,
						displayName: user.displayName || null,
						photoURL: user.photoURL || null,
						createdAt: Timestamp.now(),
						lastSeen: Timestamp.now(),
					},
					{ merge: true },
				),
				// Create trial subscription
				subscriptionRef.set({
					plan: "pro",
					source: "trial",
					expiryDate: Timestamp.fromDate(trialExpiresAt),
					billingPeriod: "trial",
					willAutoRenew: false,
					status: "trial",
					trialStartedAt: Timestamp.now(),
					updatedAt: Timestamp.now(),
				}),
			]);

			console.log(`Trial granted to ${userId}`);

			// Send email in background (don't await - don't block sign-in)
			if (email) {
				sendTrialWelcomeEmail(
					email,
					user.displayName || "there",
					trialExpiresAt,
				).catch((e) => console.error(`Email send failed: ${e}`));
			}

			return {
				customClaims: {
					plan: "pro",
					planExpiresAt: trialExpiresAt.getTime(),
				},
			};
		} catch (error) {
			console.error(`Error granting trial: ${error}`);
			// Don't block sign-in on error
			return {};
		}
	},
);
