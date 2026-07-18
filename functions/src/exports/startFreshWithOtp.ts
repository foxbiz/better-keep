import { FieldValue, Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { db, REVIEW_ACCOUNT_EMAIL, storage } from "../config";

/**
 * Deletes all notes from the user's collection.
 * @param userRef - Reference to the user document
 * @returns The number of notes deleted
 */
async function deleteAllNotes(
	userRef: FirebaseFirestore.DocumentReference,
): Promise<number> {
	const notesRef = userRef.collection("notes");
	const notesSnapshot = await notesRef.get();

	if (notesSnapshot.empty) {
		return 0;
	}

	// Delete notes in batches (Firestore batch limit is 500)
	const batchSize = 400;
	let deletedCount = 0;

	for (let i = 0; i < notesSnapshot.docs.length; i += batchSize) {
		const batch = db.batch();
		const batchDocs = notesSnapshot.docs.slice(i, i + batchSize);

		for (const doc of batchDocs) {
			batch.delete(doc.ref);
		}

		await batch.commit();
		deletedCount += batchDocs.length;
	}

	return deletedCount;
}

/**
 * Deletes all files from Cloud Storage for the user.
 * @param userId - The user ID
 * @returns The number of files deleted
 */
async function deleteUserStorage(userId: string): Promise<number> {
	try {
		const bucket = storage.bucket();
		const [files] = await bucket.getFiles({ prefix: `users/${userId}/` });

		if (files.length === 0) {
			return 0;
		}

		for (const file of files) {
			await file.delete();
		}

		return files.length;
	} catch (error) {
		// Storage errors shouldn't stop the deletion process
		console.warn(`Warning: Storage deletion issue for ${userId}:`, error);
		return 0;
	}
}

/**
 * HTTP Callable function to verify OTP and perform "start fresh" account reset.
 * This securely deletes all notes and files, clears all devices, and prepares for a new UMK.
 * REQUIRES: Valid OTP must be provided in the same request (atomic verification)
 */
export default onCall(
	async (
		request: CallableRequest<{
			otp: string;
		}>,
	) => {
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

			if (request.auth.token.email?.toLowerCase() === REVIEW_ACCOUNT_EMAIL) {
				console.log(`Skipping OTP verification for review account ${userId}`);
			} else {
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
				if (
					otpData.expiresAt &&
					otpData.expiresAt.toMillis() < now.toMillis()
				) {
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
						attempts: FieldValue.increment(1),
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
			}

			// STEP 1: Delete all existing notes
			const deletedNotesCount = await deleteAllNotes(userRef);
			console.log(`Deleted ${deletedNotesCount} notes for user ${userId}`);

			// STEP 2: Delete all files from Cloud Storage
			const deletedFilesCount = await deleteUserStorage(userId);
			console.log(
				`Deleted ${deletedFilesCount} files from storage for user ${userId}`,
			);

			// STEP 3: Delete all devices - this allows the user to start fresh
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

			// STEP 4: Delete any pending approval requests
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

			// STEP 5: Clear recovery key document if exists
			await userRef
				.collection("e2ee")
				.doc("recovery_key")
				.delete()
				.catch(() => {
					// Recovery key might not exist, ignore error
				});

			console.log(`Start fresh completed for user ${userId}`);

			return {
				success: true,
				message:
					"Account reset successful. You can now set up your account fresh.",
				deletedNotes: deletedNotesCount,
				deletedFiles: deletedFilesCount,
			};
		} catch (error) {
			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to reset account");
		}
	},
);
