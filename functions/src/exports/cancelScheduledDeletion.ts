import * as admin from "firebase-admin";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, db, emailPassword } from "../config";
import { getEmailTransporter, sendEmail } from "../utils";

/**
 * HTTP Callable function to cancel a scheduled deletion
 * Called when user signs back in before the 30-day grace period ends
 */
export default onCall(
	{ secrets: [emailPassword] },
	async (request: CallableRequest) => {
		console.log("cancelScheduledDeletion called");

		// Ensure user is authenticated
		if (!request.auth) {
			console.log("cancelScheduledDeletion: No auth context");
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to cancel deletion",
			);
		}

		const userId = request.auth.uid;
		console.log(`cancelScheduledDeletion: Processing for user ${userId}`);

		try {
			const userRef = db.collection("users").doc(userId);
			const userDoc = await userRef.get();

			if (!userDoc.exists) {
				console.log(
					`cancelScheduledDeletion: User doc not found for ${userId}`,
				);
				throw new HttpsError("not-found", "User document not found");
			}

			const data = userDoc.data();
			console.log(
				`cancelScheduledDeletion: User data scheduledDeletion = ${
					data?.scheduledDeletion ? "exists" : "null"
				}`,
			);

			if (!data?.scheduledDeletion) {
				console.log(
					`cancelScheduledDeletion: No scheduled deletion for ${userId}`,
				);
				return {
					success: true,
					message: "No scheduled deletion to cancel",
					wasScheduled: false,
				};
			}

			// Get user email for sending confirmation
			const userRecord = await auth.getUser(userId);
			const email = userRecord.email;

			// Remove the scheduled deletion field and tokensRevokedAt
			await userRef.update({
				scheduledDeletion: admin.firestore.FieldValue.delete(),
				tokensRevokedAt: admin.firestore.FieldValue.delete(),
			});

			console.log(`Cancelled scheduled deletion for user: ${userId}`);

			// Send cancellation confirmation email
			if (email) {
				try {
					const transporter = getEmailTransporter(emailPassword.value());
					const senderEmail = process.env.EMAIL_FROM;
					const senderName = process.env.EMAIL_NAME;

					const mailOptions = {
						from: `"${senderName}" <${senderEmail}>`,
						to: email,
						subject: "Account Deletion Cancelled - Better Keep Notes",
						html: `
              <!DOCTYPE html>
              <html>
              <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
              </head>
              <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
                <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
                  <h1 style="color: #2e7d32; font-size: 24px; margin-bottom: 16px; text-align: center;">Account Restored!</h1>
                  <p style="color: #333; font-size: 16px; line-height: 1.5; text-align: center;">
                    Good news! Your Better Keep Notes account deletion has been cancelled.
                  </p>
                  <div style="background: #e8f5e9; border-radius: 8px; padding: 16px; margin: 24px 0;">
                    <p style="color: #1b5e20; font-size: 14px; margin: 0; text-align: center;">
                      <strong>Your account is safe and all your data remains intact.</strong>
                    </p>
                  </div>
                  <p style="color: #666; font-size: 14px; line-height: 1.5;">
                    You signed back in, which automatically cancelled the scheduled deletion. Your notes, attachments, and all data are exactly as you left them.
                  </p>
                  <p style="color: #666; font-size: 14px; line-height: 1.5;">
                    Thank you for staying with Better Keep Notes!
                  </p>
                  <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
                  <p style="color: #999; font-size: 12px; text-align: center;">
                    If you did not sign in or did not expect this email, please secure your account immediately.
                  </p>
                  <p style="color: #bbb; font-size: 11px; margin-top: 8px; text-align: center;">
                    Better Keep by Foxbiz Software Pvt. Ltd.
                  </p>
                </div>
              </body>
              </html>
            `,
						text: `
Account Restored - Better Keep Notes

Good news! Your Better Keep Notes account deletion has been cancelled.

Your account is safe and all your data remains intact.

You signed back in, which automatically cancelled the scheduled deletion. Your notes, attachments, and all data are exactly as you left them.

Thank you for staying with Better Keep Notes!

If you did not sign in or did not expect this email, please secure your account immediately.
            `,
					};

					await sendEmail(transporter, mailOptions);
					console.log(`Sent deletion cancellation email to ${email}`);
				} catch (emailError) {
					console.error(`Failed to send cancellation email: ${emailError}`);
					// Don't fail the operation if email fails
				}
			}

			return {
				success: true,
				message: "Account deletion cancelled successfully",
				wasScheduled: true,
			};
		} catch (error) {
			console.error(`Error cancelling deletion for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to cancel account deletion");
		}
	},
);
