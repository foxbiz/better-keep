import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, db, emailPassword } from "../config";
import { generateOtpEmailHtml, generateOtpEmailText } from "../email_templates";
import type { OtpEmailConfig } from "../types";
import { generateOtp, getEmailTransporter, sendEmail } from "../utils";

/**
 * HTTP Callable function to send OTP for "start fresh" account reset verification.
 * This is used when a user has no approved devices and wants to reset their account.
 */
export default onCall(
	{ secrets: [emailPassword] },
	async (request: CallableRequest) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to request OTP",
			);
		}

		const userId = request.auth.uid;

		try {
			// Get user's email from Firebase Auth
			const userRecord = await auth.getUser(userId);
			const email = userRecord.email;

			if (!email) {
				throw new HttpsError(
					"failed-precondition",
					"No email associated with this account",
				);
			}

			// Ensure user document exists (required for subcollection)
			const userRef = db.collection("users").doc(userId);
			const userDoc = await userRef.get();
			if (!userDoc.exists) {
				// Create minimal user document if it doesn't exist
				await userRef.set({
					email: email,
					createdAt: Timestamp.now(),
				});
			}

			// Generate OTP
			const otp = generateOtp();
			const expiresAt = Timestamp.fromMillis(
				Date.now() + 10 * 60 * 1000, // 10 minutes expiry
			);

			// Store OTP in Firestore (using 'startFresh' doc to separate from deletion)
			await userRef.collection("otpVerification").doc("startFresh").set({
				otp: otp,
				expiresAt: expiresAt,
				attempts: 0,
				createdAt: Timestamp.now(),
			});

			// Send email
			const transporter = getEmailTransporter(emailPassword.value());
			const senderEmail = process.env.EMAIL_FROM;
			const senderName = process.env.EMAIL_NAME;

			const emailConfig: OtpEmailConfig = {
				title: "Account Reset Request",
				description:
					"You have requested to reset your Better Keep Notes account. This will clear all device authorizations. Enter this code to verify:",
				otp: otp,
				theme: "warning",
				securityNote:
					"Your existing encrypted notes will become permanently inaccessible after this reset. If you did not request this, please ignore this email.",
			};

			const mailOptions = {
				from: `"${senderName}" <${senderEmail}>`,
				to: email,
				subject: "Account Reset Verification Code - Better Keep",
				html: generateOtpEmailHtml(emailConfig),
				text: generateOtpEmailText(emailConfig),
			};

			await sendEmail(transporter, mailOptions);

			// Mask email for display
			const maskedEmail = email.replace(
				/(.{2})(.*)(@.*)/,
				(_, start, middle, end) =>
					start + "*".repeat(Math.min(middle.length, 5)) + end,
			);

			console.log(`Sent start fresh OTP to user ${userId} (${maskedEmail})`);

			return {
				success: true,
				message: "Verification code sent",
				email: maskedEmail,
				expiresIn: 600, // 10 minutes in seconds
			};
		} catch (error) {
			console.error(`Error sending start fresh OTP to ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to send verification code");
		}
	},
);
