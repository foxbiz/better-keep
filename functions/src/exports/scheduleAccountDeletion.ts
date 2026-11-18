import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import {
	deletionDateLabel,
	requireDeletionEnabled,
	scheduleDeletion,
} from "../accountDeletionLifecycle";
import { auth, db, emailPassword } from "../config";
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
		requireDeletionEnabled();
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
						html: `
              <!DOCTYPE html>
              <html>
              <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
              </head>
              <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
                <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
                  <h1 style="color: #d32f2f; font-size: 24px; margin-bottom: 16px;">Account Deletion Scheduled</h1>
                  <p style="color: #333; font-size: 16px; line-height: 1.5;">
                    Your Better Keep Notes account has been scheduled for deletion.
                  </p>
                  <div style="background: #fff3e0; border-radius: 8px; padding: 16px; margin: 24px 0; border-left: 4px solid #ff9800;">
                    <p style="color: #e65100; font-size: 14px; margin: 0;">
                      <strong>Eligible for deletion from:</strong> ${deleteDate}
                    </p>
                  </div>
                  <h2 style="color: #333; font-size: 18px; margin-top: 24px;">What happens next?</h2>
                  <ul style="color: #666; font-size: 14px; line-height: 1.8; padding-left: 20px;">
                    <li>Other devices may take time to sign out; sign in again to cancel deletion</li>
                    <li>Your data remains intact during the 30-day grace period</li>
                    <li>A reminder email is scheduled before your account becomes eligible for deletion</li>
                    <li>Your account becomes eligible for permanent deletion from ${deleteDate}</li>
                  </ul>
                  <h2 style="color: #1976d2; font-size: 18px; margin-top: 24px;">Changed your mind?</h2>
                  <p style="color: #333; font-size: 14px; line-height: 1.5;">
                    To cancel the deletion and keep your account:
                  </p>
                  <ol style="color: #666; font-size: 14px; line-height: 1.8; padding-left: 20px;">
                    <li>Open the Better Keep app</li>
                    <li>Sign in with your account</li>
                    <li>The deletion will be automatically cancelled</li>
                  </ol>
                  <div style="background: #e3f2fd; border-radius: 8px; padding: 16px; margin: 24px 0;">
                    <p style="color: #1565c0; font-size: 14px; margin: 0;">
                      <strong>Simply sign in again before ${deleteDate} to cancel.</strong>
                    </p>
                  </div>
                  <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
                  <p style="color: #999; font-size: 12px;">
                    If you did not request this deletion, please sign in immediately to secure your account, or contact us at support@betterkeep.app
                  </p>
                  <p style="color: #bbb; font-size: 11px; margin-top: 8px;">
                    Better Keep by Foxbiz Software Pvt. Ltd.
                  </p>
                </div>
              </body>
              </html>
            `,
						text: `
Better Keep Notes - Account Deletion Scheduled

Your Better Keep Notes account has been scheduled for deletion.

Eligible for deletion from: ${deleteDate}

What happens next?
- Other devices may take time to sign out; sign in again to cancel deletion
- Your data remains intact during the 30-day grace period
- A reminder email is scheduled before your account becomes eligible for deletion
- Your account becomes eligible for permanent deletion from ${deleteDate}

Changed your mind?
To cancel the deletion and keep your account:
1. Open the Better Keep app
2. Sign in with your account
3. The deletion will be automatically cancelled

Simply sign in again before ${deleteDate} to cancel.

If you did not request this deletion, please sign in immediately to secure your account.
            `,
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
