import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import {
	deletionDateLabel,
	scheduleDeletion,
} from "../accountDeletionLifecycle";
import { auth, db, emailPassword } from "../config";
import { generateTransactionalEmail } from "../email_templates";
import { onNonReviewCall } from "../nonReviewCallable";
import { sendEmail } from "../utils";

/**
 * HTTP Callable function to schedule account deletion
 * Sets a 30-day grace period before permanent deletion
 * REQUIRES: Valid OTP must be provided in the same request (atomic verification)
 */
export default onNonReviewCall(
	{ secrets: [emailPassword] },
	async (request: CallableRequest<{ otp: string }>) => {
		// Ensure user is authenticated
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to delete account",
			);
		}
		const userId = request.auth.uid;
		const providedOtp = request.data?.otp;

		// OTP is REQUIRED - this makes the operation atomic and secure
		if (!providedOtp || typeof providedOtp !== "string") {
			throw new HttpsError("invalid-argument", "Verification code is required");
		}

		try {
			const userRecord = await auth.getUser(userId);
			const email = userRecord.email;
			const { deleteAt } = await scheduleDeletion(db, userId, providedOtp);
			// The durable revoking phase fences cancellation/sign-in until the
			// retrying audit trigger has revoked Auth sessions. Preserve all data.

			// Send confirmation email with cancellation instructions
			if (email) {
				try {
					const senderEmail = process.env.EMAIL_FROM;
					const senderName = process.env.EMAIL_NAME;
					const deleteDate = deletionDateLabel(deleteAt);

					const mailOptions = {
						from: `"${senderName}" <${senderEmail}>`,
						to: email,
						subject: "Account Deletion Scheduled - Better Keep Notes",
						...generateTransactionalEmail({
							title: "Account deletion scheduled",
							category: "Account update",
							tone: "danger",
							paragraphs: [
								"Your Better Keep Notes account has been scheduled for deletion. Your data remains intact during the 30-day grace period.",
							],
							details: [
								{ label: "Eligible for deletion from", value: deleteDate },
							],
							list: {
								title: "What happens next",
								items: [
									"Other devices may take time to sign out. Sign in again to cancel deletion.",
									"A reminder email is scheduled before your account becomes eligible for deletion.",
									`Your account becomes eligible for permanent deletion from ${deleteDate}.`,
								],
							},
							notice: {
								title: "To keep your account",
								text: `Open Better Keep and sign in again before ${deleteDate}. This automatically cancels pending deletion. If you did not request deletion, sign in immediately to secure your account.`,
							},
						}),
					};

					await sendEmail(mailOptions);
					console.log(`Sent deletion confirmation email for user ${userId}`);
				} catch (emailError: unknown) {
					const errorDetails =
						emailError instanceof Error
							? { message: emailError.message, stack: emailError.stack }
							: emailError;
					console.error(
						`Failed to send confirmation email for user ${userId}:`,
						JSON.stringify(errorDetails),
					);
					// Don't fail the operation if email fails, but log extensively
				}
			} else {
				console.warn(
					`No email found for user ${userId}, skipping confirmation email`,
				);
			}

			console.log(
				`Scheduled deletion for user ${userId} at ${deleteAt
					.toDate()
					.toISOString()}`,
			);

			return {
				success: true,
				message: "Account scheduled for deletion",
				deleteAt: deleteAt.toDate().toISOString(),
			};
		} catch (error) {
			console.error(`Error scheduling deletion for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to schedule account deletion");
		}
	},
);
