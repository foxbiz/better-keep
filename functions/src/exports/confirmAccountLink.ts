import * as crypto from "node:crypto";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { ALLOWED_PROVIDERS, db } from "../config";
import type { AllowedProvider } from "../types";

/**
 * HTTP Callable function to confirm account link after OAuth
 * Validates the link token is still valid (proves OTP was verified)
 */
export default onCall(
	async (request: CallableRequest<{ linkToken: string; provider: string }>) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to confirm account link",
			);
		}

		const userId = request.auth.uid;
		const linkToken = request.data?.linkToken;
		const provider = request.data?.provider;

		if (!linkToken || typeof linkToken !== "string") {
			throw new HttpsError("invalid-argument", "Link token is required");
		}

		if (!provider || !ALLOWED_PROVIDERS.includes(provider as AllowedProvider)) {
			throw new HttpsError("invalid-argument", "Invalid provider");
		}

		try {
			const userRef = db.collection("users").doc(userId);
			const otpRef = userRef.collection("otpVerification").doc("accountLink");
			const otpDoc = await otpRef.get();

			if (!otpDoc.exists) {
				throw new HttpsError(
					"permission-denied",
					"No verified session found. Please start over.",
				);
			}

			const otpData = otpDoc.data();
			if (!otpData || !otpData.verified) {
				throw new HttpsError(
					"permission-denied",
					"OTP not verified. Please start over.",
				);
			}

			const now = Timestamp.now();

			// Check if link token expired
			if (
				otpData.linkTokenExpires &&
				otpData.linkTokenExpires.toMillis() < now.toMillis()
			) {
				await otpRef.delete();
				throw new HttpsError(
					"deadline-exceeded",
					"Link session expired. Please start over.",
				);
			}

			// Check provider matches
			if (otpData.provider !== provider) {
				throw new HttpsError(
					"invalid-argument",
					"Provider mismatch. Please start over.",
				);
			}

			// Verify link token
			const providedTokenHash = crypto
				.createHash("sha256")
				.update(linkToken)
				.digest("hex");

			if (otpData.linkTokenHash !== providedTokenHash) {
				await otpRef.delete();
				throw new HttpsError(
					"permission-denied",
					"Invalid link token. Please start over.",
				);
			}

			// Everything valid! Clean up OTP document
			await otpRef.delete();

			// Store the linked provider in user document
			// Note: We don't have providerUid here since linking is done client-side via Firebase SDK
			// The providerUid will be added on first login with this provider
			await userRef.set(
				{
					linkedProviders: {
						[provider.replace(".com", "")]: {
							linkedAt: now,
							linkedVia: "otp_verification",
						},
					},
				},
				{ merge: true },
			);

			// Log the successful link for audit
			await userRef.collection("auditLog").add({
				action: "account_linked",
				provider: provider,
				timestamp: now,
				success: true,
			});

			console.log(
				`Account link confirmed for user ${userId}, provider ${provider}`,
			);

			return {
				success: true,
				message: "Account linked successfully!",
			};
		} catch (error) {
			console.error(`Error confirming account link for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to confirm account link");
		}
	},
);
