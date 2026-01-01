import * as admin from "firebase-admin";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, db } from "../config";

/**
 * HTTP Callable function to verify OTP and mark email as verified.
 */
export default onCall(async (request: CallableRequest<{ otp: string }>) => {
	if (!request.auth) {
		throw new HttpsError(
			"unauthenticated",
			"User must be signed in to verify OTP",
		);
	}

	const userId = request.auth.uid;
	const providedOtp = request.data?.otp;

	if (!providedOtp || typeof providedOtp !== "string") {
		throw new HttpsError("invalid-argument", "OTP is required");
	}

	try {
		const otpRef = db
			.collection("users")
			.doc(userId)
			.collection("otpVerification")
			.doc("emailVerification");
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

		// Check attempts (max 5)
		if (otpData.attempts >= 5) {
			await otpRef.delete();
			throw new HttpsError(
				"resource-exhausted",
				"Too many attempts. Please request a new code.",
			);
		}

		// Verify OTP
		if (otpData.otp !== providedOtp) {
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

		// OTP is valid - mark email as verified in Firebase Auth
		await auth.updateUser(userId, {
			emailVerified: true,
		});

		// Clean up OTP document
		await otpRef.delete();

		console.log(`Email verified for user ${userId}`);

		return {
			success: true,
			message: "Email verified successfully",
		};
	} catch (error) {
		console.error(`Error verifying email OTP for ${userId}:`, error);

		if (error instanceof HttpsError) {
			throw error;
		}

		throw new HttpsError("internal", "Failed to verify code");
	}
});
