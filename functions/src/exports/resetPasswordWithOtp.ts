import * as crypto from "node:crypto";
import type { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, db } from "../config";
import { isOperatorManagedPasswordReset } from "../passwordResetPolicy";

const MAX_ATTEMPTS = 5;

/**
 * Generate a hash of email for use as document ID
 */
function hashEmail(email: string): string {
	return crypto.createHash("sha256").update(email.toLowerCase()).digest("hex");
}

/**
 * HTTP Callable function to verify OTP and reset password.
 * This is an unauthenticated endpoint.
 */
export default onCall(async (request: CallableRequest) => {
	const { email, otp, newPassword } = request.data as {
		email?: string;
		otp?: string;
		newPassword?: string;
	};

	// Validate inputs
	if (!email || typeof email !== "string") {
		throw new HttpsError("invalid-argument", "Email is required");
	}
	if (!otp || typeof otp !== "string") {
		throw new HttpsError("invalid-argument", "Verification code is required");
	}
	if (!newPassword || typeof newPassword !== "string") {
		throw new HttpsError("invalid-argument", "New password is required");
	}

	// Basic password length check (advisory, not enforced strictly)
	if (newPassword.length < 6) {
		throw new HttpsError(
			"invalid-argument",
			"Password must be at least 6 characters",
		);
	}

	const normalizedEmail = email.toLowerCase().trim();
	if (isOperatorManagedPasswordReset(normalizedEmail)) {
		throw new HttpsError(
			"permission-denied",
			"This managed account can only be reset by an operator",
		);
	}
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

		// OTP is valid - update password
		const userId = data.userId;
		if (!userId) {
			throw new HttpsError("internal", "User ID not found in OTP record");
		}

		// Update password using Firebase Admin SDK
		await auth.updateUser(userId, {
			password: newPassword,
		});

		// Delete OTP document on success
		await otpDocRef.delete();

		console.log(`Password reset successful for user: ${userId}`);

		return {
			success: true,
			message:
				"Password reset successfully. You can now sign in with your new password.",
		};
	} catch (error: unknown) {
		if (error instanceof HttpsError) {
			throw error;
		}
		console.error("Error resetting password:", error);
		throw new HttpsError(
			"internal",
			"Failed to reset password. Please try again.",
		);
	}
});
