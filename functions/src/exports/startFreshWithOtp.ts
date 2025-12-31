import * as admin from "firebase-admin";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db } from "../config";

/**
 * HTTP Callable function to verify OTP and perform "start fresh" account reset.
 * This clears all devices from Firestore, allowing the user to start fresh.
 * REQUIRES: Valid OTP must be provided in the same request (atomic verification)
 */
export default onCall(async (request: CallableRequest<{ otp: string }>) => {
	if (!request.auth) {
		throw new HttpsError(
			"unauthenticated",
			"User must be signed in to reset account",
		);
	}

	const userId = request.auth.uid;
	const providedOtp = request.data?.otp;

	// OTP is REQUIRED - this makes the operation atomic and secure
	if (!providedOtp || typeof providedOtp !== "string") {
		throw new HttpsError("invalid-argument", "Verification code is required");
	}

	try {
		const userRef = db.collection("users").doc(userId);
		const otpRef = userRef.collection("otpVerification").doc("startFresh");
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

		// Check if OTP expired (10 minutes from creation)
		if (otpData.expiresAt && otpData.expiresAt.toMillis() < now.toMillis()) {
			await otpRef.delete();
			throw new HttpsError(
				"deadline-exceeded",
				"Verification code has expired. Please request a new one.",
			);
		}

		// Check attempts (max 5)
		const attempts = otpData.attempts || 0;
		if (attempts >= 5) {
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

			const remainingAttempts = 4 - attempts;
			throw new HttpsError(
				"permission-denied",
				`Invalid code. ${remainingAttempts} attempt${
					remainingAttempts !== 1 ? "s" : ""
				} remaining.`,
			);
		}

		// OTP verified! Clean up immediately
		await otpRef.delete();
		console.log(`Start fresh OTP verified for user ${userId}`);

		// Delete all devices - this allows the user to start fresh
		const devicesRef = userRef.collection("devices");
		const devicesSnapshot = await devicesRef.get();

		if (!devicesSnapshot.empty) {
			const batch = db.batch();
			for (const deviceDoc of devicesSnapshot.docs) {
				batch.delete(deviceDoc.ref);
			}
			await batch.commit();
			console.log(
				`Deleted ${devicesSnapshot.docs.length} devices for user ${userId}`,
			);
		}

		// Delete any pending approval requests
		const approvalsRef = userRef.collection("approvalRequests");
		const approvalsSnapshot = await approvalsRef.get();

		if (!approvalsSnapshot.empty) {
			const batch = db.batch();
			for (const approvalDoc of approvalsSnapshot.docs) {
				batch.delete(approvalDoc.ref);
			}
			await batch.commit();
			console.log(
				`Deleted ${approvalsSnapshot.docs.length} approval requests for user ${userId}`,
			);
		}

		// Clear recovery key if exists
		await userRef
			.update({
				recoveryKey: admin.firestore.FieldValue.delete(),
			})
			.catch(() => {
				// User doc might not have this field, ignore error
			});

		console.log(`Start fresh completed for user ${userId}`);

		return {
			success: true,
			message:
				"Account reset successful. You can now set up your account fresh.",
		};
	} catch (error) {
		console.error(`Error during start fresh for ${userId}:`, error);

		if (error instanceof HttpsError) {
			throw error;
		}

		throw new HttpsError("internal", "Failed to reset account");
	}
});
