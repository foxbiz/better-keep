import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, db, emailPassword } from "../config";
import { generateOtpEmailHtml, generateOtpEmailText } from "../email_templates";
import type { OtpEmailConfig } from "../types";
import { generateOtp, getEmailTransporter, sendEmail } from "../utils";

/**
 * HTTP Callable function to send OTP for email verification.
 * Used during signup when user needs to verify their email address.
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

			// Check if email is already verified
			if (userRecord.emailVerified) {
				return {
					success: true,
					message: "Email is already verified",
					alreadyVerified: true,
				};
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

			// Store OTP in Firestore
			await userRef.collection("otpVerification").doc("emailVerification").set({
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
				title: "Verify Your Email",
				description:
					"Welcome to Better Keep Notes! Enter this code to verify your email address:",
				otp: otp,
				theme: "primary",
				securityNote:
					"If you did not create an account with Better Keep, please ignore this email.",
			};

			const mailOptions = {
				from: `"${senderName}" <${senderEmail}>`,
				to: email,
				subject: "Email Verification Code - Better Keep",
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

			console.log(
				`Sent email verification OTP to user ${userId} (${maskedEmail})`,
			);

			return {
				success: true,
				message: "Verification code sent",
				email: maskedEmail,
				expiresIn: 600, // 10 minutes in seconds
			};
		} catch (error) {
			console.error(
				`Error sending email verification OTP to ${userId}:`,
				error,
			);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to send verification code");
		}
	},
);
