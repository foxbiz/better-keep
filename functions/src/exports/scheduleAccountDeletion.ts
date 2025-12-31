import * as admin from "firebase-admin";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, db, emailPassword } from "../config";
import { getEmailTransporter, sendEmail } from "../utils";

/**
 * HTTP Callable function to schedule account deletion
 * Sets a 30-day grace period before permanent deletion
 * REQUIRES: Valid OTP must be provided in the same request (atomic verification)
 */
export default onCall(
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
			// Atomically verify OTP and schedule deletion in the same function
			const otpRef = db
				.collection("users")
				.doc(userId)
				.collection("otpVerification")
				.doc("deletion");
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
			console.log(`OTP verified and deleted for user ${userId}`);

			const userRef = db.collection("users").doc(userId);
			const userDoc = await userRef.get();

			if (!userDoc.exists) {
				throw new HttpsError("not-found", "User document not found");
			}

			// Get user email for sending confirmation
			const userRecord = await auth.getUser(userId);
			const email = userRecord.email;

			const deleteAt = Timestamp.fromMillis(
				now.toMillis() + 30 * 24 * 60 * 60 * 1000, // 30 days in milliseconds
			);

			// Calculate reminder date (1 day before deletion)
			const reminderAt = Timestamp.fromMillis(
				deleteAt.toMillis() - 24 * 60 * 60 * 1000, // 1 day before
			);

			// Revoke all refresh tokens to force logout on all devices
			await auth.revokeRefreshTokens(userId);
			console.log(`Revoked all refresh tokens for user ${userId}`);

			// Delete all devices except the primary (first approved) device
			// This forces other devices to re-authenticate if deletion is cancelled
			const devicesRef = userRef.collection("devices");
			const devicesSnapshot = await devicesRef.get();

			if (!devicesSnapshot.empty) {
				// Find the primary device (first approved device by approved_at date)
				const approvedDevices = devicesSnapshot.docs
					.filter(
						(doc) => doc.data().status === "approved" && doc.data().approved_at,
					)
					.sort((a, b) => {
						const aDate = new Date(a.data().approved_at);
						const bDate = new Date(b.data().approved_at);
						return aDate.getTime() - bDate.getTime();
					});

				const primaryDeviceId =
					approvedDevices.length > 0 ? approvedDevices[0].id : null;
				console.log(`Primary device ID: ${primaryDeviceId}`);

				// Delete all devices except the primary one
				const devicesToDelete = devicesSnapshot.docs.filter(
					(doc) => doc.id !== primaryDeviceId,
				);

				if (devicesToDelete.length > 0) {
					const batch = db.batch();
					for (const deviceDoc of devicesToDelete) {
						batch.delete(deviceDoc.ref);
					}
					await batch.commit();
					console.log(
						`Deleted ${devicesToDelete.length} non-primary devices for user ${userId}`,
					);
				}
			}

			// Store deletion schedule and tokensRevokedAt in Firestore
			// The tokensRevokedAt field is used by client apps to detect revocation
			await userRef.update({
				scheduledDeletion: {
					scheduledAt: now,
					deleteAt: deleteAt,
					reminderAt: reminderAt,
					reminderSent: false,
				},
				tokensRevokedAt: now,
			});
			console.log(`Updated Firestore with tokensRevokedAt for user ${userId}`);

			// Send confirmation email with cancellation instructions
			if (email) {
				try {
					const transporter = getEmailTransporter(emailPassword.value());
					const senderEmail = process.env.EMAIL_FROM;
					const senderName = process.env.EMAIL_NAME;
					const deleteDate = deleteAt.toDate().toLocaleDateString("en-US", {
						weekday: "long",
						year: "numeric",
						month: "long",
						day: "numeric",
					});

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
                      <strong>Deletion Date:</strong> ${deleteDate}
                    </p>
                  </div>
                  <h2 style="color: #333; font-size: 18px; margin-top: 24px;">What happens next?</h2>
                  <ul style="color: #666; font-size: 14px; line-height: 1.8; padding-left: 20px;">
                    <li>You have been logged out from all devices</li>
                    <li>Your data remains intact during the 30-day grace period</li>
                    <li>You will receive a reminder email 1 day before deletion</li>
                    <li>After ${deleteDate}, all data will be permanently deleted</li>
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

Deletion Date: ${deleteDate}

What happens next?
- You have been logged out from all devices
- Your data remains intact during the 30-day grace period
- You will receive a reminder email 1 day before deletion
- After ${deleteDate}, all data will be permanently deleted

Changed your mind?
To cancel the deletion and keep your account:
1. Open the Better Keep app
2. Sign in with your account
3. The deletion will be automatically cancelled

Simply sign in again before ${deleteDate} to cancel.

If you did not request this deletion, please sign in immediately to secure your account.
            `,
					};

					await sendEmail(transporter, mailOptions);
					console.log(`Sent deletion confirmation email to ${email}`);
				} catch (emailError: unknown) {
					const errorDetails =
						emailError instanceof Error
							? { message: emailError.message, stack: emailError.stack }
							: emailError;
					console.error(
						`Failed to send confirmation email to ${email}:`,
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
