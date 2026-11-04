import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import { requireDeletionEnabled } from "../accountDeletionLifecycle";
import { auth, db, emailPassword } from "../config";
import { generateOtpEmailHtml, generateOtpEmailText } from "../email_templates";
import { onNonReviewCall } from "../nonReviewCallable";
import type { OtpEmailConfig } from "../types";
import { generateOtp, sendEmail } from "../utils";

/**
 * HTTP Callable function to send OTP for account deletion verification
 */
export default onNonReviewCall(
	{ secrets: [emailPassword] },
	async (request: CallableRequest) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to request OTP",
			);
		}
		requireDeletionEnabled();
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

			const [local, domain] = email.split("@");
			const maskedEmail = `${local.length > 1 ? local[0] : ""}***@${domain}`;
			const userRef = db.collection("users").doc(userId);
			const otpRef = userRef.collection("otpVerification").doc("deletion");
			const otp = generateOtp();
			const now = Timestamp.now();
			await db.runTransaction(async (tx) => {
				const userDoc = await tx.get(userRef);
				const previous = await tx.get(otpRef);
				if (userDoc.data()?.scheduledDeletion != null) {
					throw new HttpsError(
						"failed-precondition",
						"Cancel the existing deletion request first",
					);
				}
				const createdAt = previous.data()?.createdAt;
				if (
					createdAt instanceof Timestamp &&
					now.toMillis() - createdAt.toMillis() < 60_000
				) {
					throw new HttpsError(
						"resource-exhausted",
						"Wait one minute before requesting another code",
						{
							reason: "deletion-otp-cooldown",
							email: maskedEmail,
							retryAfterSeconds: Math.ceil(
								(60_000 - now.toMillis() + createdAt.toMillis()) / 1000,
							),
						},
					);
				}
				if (!userDoc.exists) tx.create(userRef, { email, createdAt: now });
				tx.set(otpRef, {
					otp,
					expiresAt: Timestamp.fromMillis(now.toMillis() + 600_000),
					attempts: 0,
					createdAt: now,
				});
			});

			// Send email
			const senderEmail = process.env.EMAIL_FROM;
			const senderName = process.env.EMAIL_NAME;

			const emailConfig: OtpEmailConfig = {
				title: "Account Deletion Request",
				description:
					"You have requested to delete your Better Keep Notes account. Enter this code to verify:",
				otp: otp,
				theme: "danger",
				securityNote:
					"If you did not request this, please ignore this email and secure your account.",
			};

			const mailOptions = {
				from: `"${senderName}" <${senderEmail}>`,
				to: email,
				subject: "Account Deletion Verification Code - Better Keep",
				html: generateOtpEmailHtml(emailConfig),
				text: generateOtpEmailText(emailConfig),
			};

			await sendEmail(mailOptions);

			console.log(`Sent deletion OTP for user ${userId}`);

			return {
				success: true,
				message: "Verification code sent",
				email: maskedEmail,
				expiresIn: 600, // 10 minutes in seconds
			};
		} catch (error) {
			if (error instanceof HttpsError) {
				throw error;
			}

			console.error(`Error sending OTP for user ${userId}:`, error);
			throw new HttpsError("internal", "Failed to send verification code");
		}
	},
);
