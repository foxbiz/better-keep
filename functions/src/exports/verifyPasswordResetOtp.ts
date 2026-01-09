import * as crypto from "node:crypto";
import type { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db } from "../config";

const MAX_ATTEMPTS = 5;

/**
 * Generate a hash of email for use as document ID
 */
function hashEmail(email: string): string {
	return crypto.createHash("sha256").update(email.toLowerCase()).digest("hex");
}

/**
 * HTTP Callable function to verify OTP for password reset.
 * This only verifies the OTP is correct, does not reset the password.
 * Call resetPasswordWithOtp after this to actually reset the password.
 */
export default onCall(async (request: CallableRequest) => {
	const { email, otp } = request.data as {
		email?: string;
		otp?: string;
	};

	// Validate inputs
	if (!email || typeof email !== "string") {
		throw new HttpsError("invalid-argument", "Email is required");
	}
	if (!otp || typeof otp !== "string") {
		throw new HttpsError("invalid-argument", "Verification code is required");
	}

	const normalizedEmail = email.toLowerCase().trim();
	const emailHash = hashEmail(normalizedEmail);
	const otpDocRef = db.collection("passwordResetOtps").doc(emailHash);

	try {
		// Get OTP document
		const otpDoc = await otpDocRef.get();

		if (!otpDoc.exists) {
			throw new HttpsError(
				"not-found",
				"No password reset request found. Please request a new code.",
			);
		}

		const data = otpDoc.data();
		if (!data) {
			throw new HttpsError("internal", "Invalid OTP data");
		}

		// Check if expired
		const expiresAt = data.expiresAt as Timestamp;
		if (expiresAt.toMillis() < Date.now()) {
			// Delete expired OTP
			await otpDocRef.delete();
			throw new HttpsError(
				"deadline-exceeded",
				"Verification code has expired. Please request a new one.",
			);
		}

		// Check attempts
		const attempts = (data.attempts || 0) + 1;
		if (attempts > MAX_ATTEMPTS) {
			// Delete OTP after too many attempts
			await otpDocRef.delete();
			throw new HttpsError(
				"resource-exhausted",
				"Too many failed attempts. Please request a new code.",
			);
		}

		// Verify OTP
		if (data.otp !== otp) {
			// Increment attempts
			await otpDocRef.update({
				attempts: attempts,
			});
			throw new HttpsError(
				"permission-denied",
				`Invalid verification code. ${MAX_ATTEMPTS - attempts} attempts remaining.`,
			);
		}

		// OTP is valid - mark as verified but don't delete yet
		// The OTP will be verified again and deleted when password is actually reset
		await otpDocRef.update({
			verified: true,
			verifiedAt: new Date().toISOString(),
		});

		console.log(`OTP verified for password reset: ${normalizedEmail}`);

		return {
			success: true,
			message: "Verification code is correct. You can now set a new password.",
		};
	} catch (error: unknown) {
		if (error instanceof HttpsError) {
			throw error;
		}
		console.error("Error verifying password reset OTP:", error);
		throw new HttpsError(
			"internal",
			"Failed to verify code. Please try again.",
		);
	}
});
