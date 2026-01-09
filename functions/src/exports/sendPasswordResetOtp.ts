import * as crypto from "node:crypto";
import type { UserRecord } from "firebase-admin/auth";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { auth, db, emailPassword } from "../config";
import { generateOtpEmailHtml, generateOtpEmailText } from "../email_templates";
import type { OtpEmailConfig } from "../types";
import { generateOtp, getEmailTransporter, sendEmail } from "../utils";

// Rate limit: max 3 OTP requests per email per hour
const MAX_REQUESTS_PER_HOUR = 3;
const RATE_LIMIT_WINDOW_MS = 60 * 60 * 1000; // 1 hour
const OTP_EXPIRY_MINUTES = 10;

/**
 * Generate a hash of email for use as document ID
 * This avoids using email directly in document paths
 */
function hashEmail(email: string): string {
	return crypto.createHash("sha256").update(email.toLowerCase()).digest("hex");
}

/**
 * HTTP Callable function to send OTP for password reset.
 * This is an unauthenticated endpoint (user forgot password, can't sign in).
 * Rate limited to prevent abuse.
 */
export default onCall(
	{ secrets: [emailPassword] },
	async (request: CallableRequest) => {
		const { email } = request.data as { email?: string };

		if (!email || typeof email !== "string") {
			throw new HttpsError("invalid-argument", "Email is required");
		}

		const normalizedEmail = email.toLowerCase().trim();

		// Validate email format
		const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
		if (!emailRegex.test(normalizedEmail)) {
			throw new HttpsError("invalid-argument", "Invalid email format");
		}

		try {
			// Check if user exists in Firebase Auth
			let userRecord: UserRecord | undefined;
			try {
				userRecord = await auth.getUserByEmail(normalizedEmail);
			} catch (_error: unknown) {
				// Don't reveal if user exists - return generic success
				// This prevents email enumeration attacks
				console.log(
					`Password reset requested for non-existent email: ${normalizedEmail}`,
				);
				return {
					success: true,
					message:
						"If an account exists with this email, you will receive a verification code.",
					maskedEmail: maskEmail(normalizedEmail),
				};
			}

			const emailHash = hashEmail(normalizedEmail);
			const otpDocRef = db.collection("passwordResetOtps").doc(emailHash);

			// Check rate limiting
			const existingDoc = await otpDocRef.get();
			if (existingDoc.exists) {
				const data = existingDoc.data();
				if (data) {
					const requests = data.requests || [];
					const now = Date.now();
					const recentRequests = requests.filter(
						(timestamp: number) => now - timestamp < RATE_LIMIT_WINDOW_MS,
					);

					if (recentRequests.length >= MAX_REQUESTS_PER_HOUR) {
						const oldestRequest = Math.min(...recentRequests);
						const waitMinutes = Math.ceil(
							(RATE_LIMIT_WINDOW_MS - (now - oldestRequest)) / 60000,
						);
						throw new HttpsError(
							"resource-exhausted",
							`Too many reset attempts. Please try again in ${waitMinutes} minutes.`,
						);
					}
				}
			}

			// Generate OTP
			const otp = generateOtp();
			const expiresAt = Timestamp.fromMillis(
				Date.now() + OTP_EXPIRY_MINUTES * 60 * 1000,
			);

			// Get existing requests for rate limiting
			const existingData = existingDoc.exists ? existingDoc.data() : null;
			const existingRequests = existingData?.requests || [];
			const now = Date.now();
			const recentRequests = existingRequests.filter(
				(timestamp: number) => now - timestamp < RATE_LIMIT_WINDOW_MS,
			);

			// Store OTP with rate limit tracking
			await otpDocRef.set({
				otp: otp,
				expiresAt: expiresAt,
				attempts: 0,
				createdAt: Timestamp.now(),
				userId: userRecord.uid,
				email: normalizedEmail,
				requests: [...recentRequests, now],
			});

			// Send email
			const transporter = getEmailTransporter(emailPassword.value());
			const senderEmail = process.env.EMAIL_FROM;
			const senderName = process.env.EMAIL_NAME;

			const emailConfig: OtpEmailConfig = {
				title: "Reset Your Password",
				description:
					"You requested to reset your password. Enter this code in the app to continue:",
				otp: otp,
				theme: "danger",
				securityNote:
					"If you did not request a password reset, please ignore this email. Your password will remain unchanged.",
				expiresInMinutes: OTP_EXPIRY_MINUTES,
			};

			const mailOptions = {
				from: `"${senderName}" <${senderEmail}>`,
				to: normalizedEmail,
				subject: "Password Reset Code - Better Keep",
				html: generateOtpEmailHtml(emailConfig),
				text: generateOtpEmailText(emailConfig),
			};

			await sendEmail(transporter, mailOptions);

			console.log(`Password reset OTP sent to: ${normalizedEmail}`);

			return {
				success: true,
				message: "Verification code sent to your email",
				maskedEmail: maskEmail(normalizedEmail),
			};
		} catch (error: unknown) {
			if (error instanceof HttpsError) {
				throw error;
			}
			console.error("Error sending password reset OTP:", error);
			throw new HttpsError(
				"internal",
				"Failed to send verification code. Please try again.",
			);
		}
	},
);

/**
 * Mask email for display (e.g., "jo***@example.com")
 */
function maskEmail(email: string): string {
	return email.replace(
		/(.{2})(.*)(@.*)/,
		(_, start, middle, end) =>
			start + "*".repeat(Math.min(middle.length, 5)) + end,
	);
}
