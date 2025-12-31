import * as crypto from "node:crypto";
import * as admin from "firebase-admin";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { ALLOWED_PROVIDERS, db } from "../config";
import type { AllowedProvider } from "../types";

/**
 * HTTP Callable function to verify OTP for account linking
 * Returns a short-lived link token that must be used within 2 minutes
 */
export default onCall(
	async (request: CallableRequest<{ otp: string; provider: string }>) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to verify OTP",
			);
		}

		const userId = request.auth.uid;
		const providedOtp = request.data?.otp;
		const provider = request.data?.provider;

		if (!providedOtp || typeof providedOtp !== "string") {
			throw new HttpsError("invalid-argument", "Verification code is required");
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
					"not-found",
					"No verification code found. Please request a new one.",
				);
			}

			const otpData = otpDoc.data();
			if (!otpData) {
				throw new HttpsError(
					"not-found",
					"No verification code found. Please request a new one.",
				);
			}

			const now = Timestamp.now();

			// Check if expired
			if (otpData.expiresAt.toMillis() < now.toMillis()) {
				await otpRef.delete();
				throw new HttpsError(
					"deadline-exceeded",
					"Verification code has expired. Please request a new one.",
				);
			}

			// Check provider matches
			if (otpData.provider !== provider) {
				throw new HttpsError(
					"invalid-argument",
					"Provider mismatch. Please request a new code for this provider.",
				);
			}

			// Check attempts (max 5)
			if (otpData.attempts >= 5) {
				await otpRef.delete();
				throw new HttpsError(
					"resource-exhausted",
					"Too many attempts. Please request a new code.",
				);
			}

			// Verify OTP by comparing hashes
			const providedOtpHash = crypto
				.createHash("sha256")
				.update(providedOtp)
				.digest("hex");

			if (otpData.otpHash !== providedOtpHash) {
				await otpRef.update({
					attempts: admin.firestore.FieldValue.increment(1),
				});

				const remainingAttempts = 4 - otpData.attempts;
				throw new HttpsError(
					"permission-denied",
					`Invalid code. ${remainingAttempts} attempt${
						remainingAttempts !== 1 ? "s" : ""
					} remaining.`,
				);
			}

			// OTP verified! Generate a one-time link token
			const linkToken = crypto.randomBytes(32).toString("hex");
			const linkTokenHash = crypto
				.createHash("sha256")
				.update(linkToken)
				.digest("hex");
			const linkTokenExpires = Timestamp.fromMillis(
				Date.now() + 2 * 60 * 1000, // 2 minutes to complete OAuth
			);

			// Store verified status with link token
			await otpRef.set({
				verified: true,
				verifiedAt: now,
				linkTokenHash: linkTokenHash,
				linkTokenExpires: linkTokenExpires,
				provider: provider,
			});

			console.log(
				`Account link OTP verified for user ${userId}, provider ${provider}`,
			);

			return {
				success: true,
				message: "Verification successful. Complete the linking now.",
				linkToken: linkToken,
				provider: provider,
				tokenExpiresIn: 120, // 2 minutes to complete OAuth
			};
		} catch (error) {
			console.error(`Error verifying account link OTP for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to verify code");
		}
	},
);
