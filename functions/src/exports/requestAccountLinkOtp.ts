import * as crypto from "node:crypto";
import { Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import {
	ACCOUNT_LINK_PROVIDERS,
	accountLinkProviderDisplayName,
	isAccountLinkProvider,
} from "../accountLinkProviders";
import { auth, db, emailPassword } from "../config";
import { generateOtpEmailHtml, generateOtpEmailText } from "../email_templates";
import { onNonReviewCall } from "../nonReviewCallable";
import type { OtpEmailConfig } from "../types";
import { generateOtp, sendEmail } from "../utils";

/**
 * HTTP Callable function to request OTP for account linking
 * Sends a 6-digit OTP to the user's primary email to verify they own the account
 */
export default onNonReviewCall(
	{ secrets: [emailPassword] },
	async (request: CallableRequest<{ provider: string }>) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to link accounts",
			);
		}
		const userId = request.auth.uid;
		const provider = request.data?.provider;

		// Validate provider
		if (!isAccountLinkProvider(provider)) {
			throw new HttpsError(
				"invalid-argument",
				`Invalid provider. Allowed: ${ACCOUNT_LINK_PROVIDERS.join(", ")}`,
			);
		}

		try {
			// Get user's email from Firebase Auth
			const userRecord = await auth.getUser(userId);
			const email = userRecord.email;

			if (!email) {
				throw new HttpsError(
					"failed-precondition",
					"No email associated with this account. Cannot verify ownership.",
				);
			}

			// Check if provider is already linked
			const existingProviders = userRecord.providerData.map(
				(p) => p.providerId,
			);
			if (existingProviders.includes(provider)) {
				throw new HttpsError(
					"already-exists",
					"This provider is already linked to your account.",
				);
			}

			// Rate limiting: Check for recent OTP requests
			const userRef = db.collection("users").doc(userId);
			const otpRef = userRef.collection("otpVerification").doc("accountLink");
			const existingOtp = await otpRef.get();

			if (existingOtp.exists) {
				const data = existingOtp.data();
				if (data) {
					const createdAt = data.createdAt?.toMillis() || 0;
					const timeSinceLastRequest = Date.now() - createdAt;
					// Prevent requesting new OTP within 60 seconds
					if (timeSinceLastRequest < 60 * 1000) {
						const waitSeconds = Math.ceil(
							(60 * 1000 - timeSinceLastRequest) / 1000,
						);
						throw new HttpsError(
							"resource-exhausted",
							`Please wait ${waitSeconds} seconds before requesting a new code.`,
						);
					}
				}
			}

			// Generate OTP
			const otp = generateOtp();
			const expiresAt = Timestamp.fromMillis(
				Date.now() + 10 * 60 * 1000, // 10 minutes expiry
			);

			// Hash OTP for storage (extra security - we compare hashes)
			const otpHash = crypto.createHash("sha256").update(otp).digest("hex");

			// Store OTP in Firestore
			await otpRef.set({
				otpHash: otpHash,
				provider: provider,
				expiresAt: expiresAt,
				attempts: 0,
				createdAt: Timestamp.now(),
			});

			const providerName = accountLinkProviderDisplayName(provider);

			// Send email
			const senderEmail = process.env.EMAIL_FROM;
			const senderName = process.env.EMAIL_NAME;

			const emailConfig: OtpEmailConfig = {
				title: `Link ${providerName} Account`,
				description: `You requested to link your <strong>${providerName}</strong> account to Better Keep. Enter this code to verify:`,
				otp: otp,
				theme: "primary",
				securityNote:
					"If you didn't request this, please ignore this email. Never share this code with anyone.",
			};

			const mailOptions = {
				from: `"${senderName}" <${senderEmail}>`,
				to: email,
				subject: `Verify Account Link - ${providerName} - Better Keep`,
				html: generateOtpEmailHtml(emailConfig),
				text: generateOtpEmailText(emailConfig),
			};

			await sendEmail(mailOptions);

			// Mask email for display
			const maskedEmail = email.replace(
				/(.{2})(.*)(@.*)/,
				(_, start, middle, end) =>
					start + "*".repeat(Math.min(middle.length, 5)) + end,
			);

			console.log(
				`Sent account link OTP to user ${userId} (${maskedEmail}) for provider ${provider}`,
			);

			return {
				success: true,
				message: "Verification code sent",
				email: maskedEmail,
				provider: provider,
				expiresIn: 600, // 10 minutes in seconds
			};
		} catch (error) {
			console.error(
				`Error sending account link OTP to ${userId} for ${provider}:`,
				error,
			);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to send verification code");
		}
	},
);
