import * as crypto from "node:crypto";
import * as admin from "firebase-admin";
import { FieldValue, getFirestore, Timestamp } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall, onRequest } from "firebase-functions/v2/https";
import { beforeUserSignedIn } from "firebase-functions/v2/identity";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { google } from "googleapis";
import * as nodemailer from "nodemailer";

const app = admin.initializeApp();

// Check if running in emulator - emulator only supports default database
const isEmulator = process.env.FUNCTIONS_EMULATOR === "true";
const databaseId = isEmulator ? "(default)" : "better-keep";

// Use the named database 'better-keep' in production, default in emulator
const db = getFirestore(app, databaseId);

const auth = admin.auth();
const storage = admin.storage();
const emailPassword = defineSecret("EMAIL_PASSWORD");

// Google Play API credentials (service account JSON as base64 or JSON string)
const googlePlayCredentials = defineSecret("GOOGLE_PLAY_CREDENTIALS");

// Razorpay API credentials
const razorpayKeyId = defineSecret("RAZORPAY_KEY_ID");
const razorpayKeySecret = defineSecret("RAZORPAY_KEY_SECRET");

// OAuth secrets for direct OAuth flow (bypasses Firebase SDK storage issues)
const facebookAppId = defineSecret("FACEBOOK_APP_ID");
const facebookAppSecret = defineSecret("FACEBOOK_APP_SECRET");
const githubClientId = defineSecret("GITHUB_CLIENT_ID");
const githubClientSecret = defineSecret("GITHUB_CLIENT_SECRET");
const twitterClientId = defineSecret("TWITTER_CLIENT_ID");
const twitterClientSecret = defineSecret("TWITTER_CLIENT_SECRET");

// Razorpay pricing (in paise - 100 paise = ₹1)
const RAZORPAY_PLANS = {
	monthly: {
		amount: 23000, // ₹230
		currency: "INR",
		period: "monthly",
		interval: 1,
		name: "Better Keep Pro Monthly",
	},
	yearly: {
		amount: 162500, // ₹1625
		currency: "INR",
		period: "yearly",
		interval: 1,
		name: "Better Keep Pro Yearly",
	},
};

// Constants for subscription
const ANDROID_PACKAGE_NAME = "io.foxbiz.better_keep";
const SUBSCRIPTION_PRODUCT_ID = "better_keep_pro";

// Subscription plans
interface SubscriptionPlan {
	basePlanId: string;
	displayName: string;
	periodDays: number;
}

const SUBSCRIPTION_PLANS: Record<string, SubscriptionPlan> = {
	"pro-monthly": {
		basePlanId: "pro-monthly",
		displayName: "Pro Monthly",
		periodDays: 30,
	},
	"pro-yearly": {
		basePlanId: "pro-yearly",
		displayName: "Pro Yearly",
		periodDays: 365,
	},
};

// Trial configuration (can be controlled via environment variables)
const TRIAL_ENABLED = process.env.TRIAL_ENABLED === "true";
const TRIAL_DAYS = parseInt(process.env.TRIAL_DAYS || "7", 10);
// Debug mode: use minutes instead of days for testing (only in emulator)
const DEBUG_TRIAL_MINUTES =
	isEmulator && process.env.DEBUG_TRIAL_MINUTES
		? parseInt(process.env.DEBUG_TRIAL_MINUTES, 10)
		: null;

/**
 * Set custom claims on user's Firebase Auth token for subscription status.
 * This enables server-side enforcement of subscription gating in Firestore/Storage rules.
 *
 * @param userId - The Firebase Auth user ID
 * @param plan - The subscription plan ('pro' or 'free')
 * @param expiresAt - When the subscription expires (null for free plan)
 */
async function setSubscriptionClaims(
	userId: string,
	plan: "pro" | "free",
	expiresAt: Date | null,
): Promise<void> {
	try {
		if (plan === "pro" && expiresAt) {
			await auth.setCustomUserClaims(userId, {
				plan: "pro",
				planExpiresAt: expiresAt.getTime(),
			});
			console.log(
				`Set Pro claims for user ${userId}, expires ${expiresAt.toISOString()}`,
			);
		} else {
			// Clear claims for free users
			await auth.setCustomUserClaims(userId, {
				plan: "free",
				planExpiresAt: null,
			});
			console.log(`Cleared Pro claims for user ${userId} (now free)`);
		}
	} catch (error) {
		console.error(`Error setting subscription claims for ${userId}:`, error);
		// Don't throw - claims are a security enhancement, not critical path
	}
}

/**
 * Get Google Play Android Publisher API client
 */
async function getPlayDeveloperApi(credentialsJson: string) {
	const credentials = JSON.parse(credentialsJson);
	const authClient = new google.auth.GoogleAuth({
		credentials,
		scopes: ["https://www.googleapis.com/auth/androidpublisher"],
	});

	return google.androidpublisher({
		version: "v3",
		auth: authClient,
	});
}

const getEmailTransporter = (password: string) => {
	const host = process.env.EMAIL_HOST;
	const port = process.env.EMAIL_PORT;

	if (!host || !port) {
		throw new Error(
			"EMAIL_HOST and EMAIL_PORT environment variables must be set",
		);
	}

	return nodemailer.createTransport({
		host: host,
		port: parseInt(port, 10),
		secure: process.env.EMAIL_SECURE !== "false", // default true for port 465
		auth: {
			user: process.env.EMAIL_USER,
			pass: password,
		},
	});
};

/**
 * Send an email or log it in emulator mode
 * In emulator mode, emails are logged instead of being sent
 */
async function sendEmail(
	transporter: nodemailer.Transporter,
	mailOptions: nodemailer.SendMailOptions,
): Promise<void> {
	if (isEmulator) {
		console.log("📧 [EMULATOR] Email would be sent:");
		console.log("  From:", mailOptions.from);
		console.log("  To:", mailOptions.to);
		console.log("  Subject:", mailOptions.subject);
		console.log(
			"  Text preview:",
			typeof mailOptions.text === "string"
				? `${mailOptions.text.substring(0, 200)}...`
				: "(HTML only)",
		);
		return;
	}
	await transporter.sendMail(mailOptions);
}

/**
 * Generates a cryptographically secure 6-digit OTP
 */
function generateOtp(): string {
	const randomBytes = crypto.randomBytes(4);
	const randomNumber = randomBytes.readUInt32BE(0);
	// Map to 6-digit range (100000-999999)
	const otp = 100000 + (randomNumber % 900000);
	return otp.toString();
}

/**
 * Configuration for OTP email template
 */
interface OtpEmailConfig {
	/** Title displayed at the top of the email */
	title: string;
	/** Main description text */
	description: string;
	/** The 6-digit OTP code */
	otp: string;
	/** Theme color - 'primary' (purple), 'warning' (orange), or 'danger' (red) */
	theme: "primary" | "warning" | "danger";
	/** Optional security warning message */
	securityNote?: string;
	/** Minutes until expiry (default: 10) */
	expiresInMinutes?: number;
}

/**
 * Generates a consistent, beautiful OTP email HTML template
 * Uses a unified design across all OTP emails in the app
 */
function generateOtpEmailHtml(config: OtpEmailConfig): string {
	const {
		title,
		description,
		otp,
		theme,
		securityNote,
		expiresInMinutes = 10,
	} = config;

	// Theme colors
	const themeColors = {
		primary: { bg: "#6750A4", light: "#F3E5F5", text: "#6750A4" },
		warning: { bg: "#FF9800", light: "#FFF3E0", text: "#E65100" },
		danger: { bg: "#D32F2F", light: "#FFEBEE", text: "#C62828" },
	};
	const colors = themeColors[theme];

	return `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
  <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
    <h1 style="color: ${colors.text}; font-size: 24px; margin-bottom: 16px; text-align: center;">${title}</h1>
    <p style="color: #333; font-size: 16px; line-height: 1.5; text-align: center;">
      ${description}
    </p>
    <div style="background: ${colors.bg}; border-radius: 12px; padding: 24px; text-align: center; margin: 24px 0;">
      <p style="color: rgba(255,255,255,0.8); font-size: 14px; margin: 0 0 8px 0;">Your verification code</p>
      <span style="font-size: 32px; font-weight: bold; letter-spacing: 12px; color: white; font-family: 'SF Mono', Monaco, 'Courier New', monospace; white-space: nowrap;">${otp}</span>
    </div>
    <p style="color: #666; font-size: 14px; line-height: 1.5; text-align: center;">
      This code expires in <strong>${expiresInMinutes} minutes</strong>.
    </p>
    ${
			securityNote
				? `
    <div style="background: ${colors.light}; border-radius: 8px; padding: 16px; margin: 16px 0; border-left: 4px solid ${colors.bg};">
      <p style="color: ${colors.text}; font-size: 14px; margin: 0;">
        <strong>⚠️ Security:</strong> ${securityNote}
      </p>
    </div>
    `
				: ""
		}
    <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
    <p style="color: #999; font-size: 12px; text-align: center;">
      If you have questions, contact us at support@betterkeep.app
    </p>
    <p style="color: #bbb; font-size: 11px; margin-top: 8px; text-align: center;">
      Better Keep by Foxbiz Software Pvt. Ltd.
    </p>
  </div>
</body>
</html>
`;
}

/**
 * Generates plain text version of OTP email
 */
function generateOtpEmailText(config: OtpEmailConfig): string {
	const { title, description, otp, securityNote, expiresInMinutes = 10 } = config;

	return `
${title}

${description}

Your verification code: ${otp}

This code expires in ${expiresInMinutes} minutes.
${securityNote ? `\nSecurity: ${securityNote}\n` : ""}
If you have questions, contact us at support@betterkeep.app

Better Keep by Foxbiz Software Pvt. Ltd.
`.trim();
}

// ============================================================
// CUSTOM TOKEN FOR MOBILE OAUTH
// ============================================================

/**
 * Creates a custom token for a user who authenticated via web OAuth
 * This allows the mobile app to sign in after web-based OAuth
 */
export const createCustomToken = onCall(async (request: CallableRequest) => {
	// User must be authenticated (they just signed in via web OAuth)
	if (!request.auth) {
		throw new HttpsError(
			"unauthenticated",
			"User must be signed in to get a custom token",
		);
	}

	const uid = request.auth.uid;

	try {
		// Create a custom token for this user
		const customToken = await auth.createCustomToken(uid);

		return { token: customToken };
	} catch (error) {
		console.error("Error creating custom token:", error);
		throw new HttpsError("internal", "Failed to create authentication token");
	}
});

// ============================================================
// DIRECT OAUTH FLOW (bypasses Firebase SDK storage issues)
// ============================================================

interface OAuthState {
	provider: string;
	redirect: string;
	nonce?: string;
	mode?: 'signin' | 'link';
	linkingUserId?: string;
}

/**
 * Start OAuth flow - redirects to provider's authorization page
 * URL: /oauthStart?provider=facebook&redirect=betterkeep&mode=signin
 * For linking: /oauthStart?provider=facebook&redirect=betterkeep&mode=link&uid=USER_UID
 */
export const oauthStart = onRequest(
	{
		secrets: [
			facebookAppId,
			githubClientId,
			twitterClientId,
			twitterClientSecret,
		],
		cors: true,
	},
	async (req, res) => {
		const provider = req.query.provider as string;
		const redirect = (req.query.redirect as string) || "betterkeep";
		const mode = (req.query.mode as 'signin' | 'link') || "signin";
		const linkingUserId = req.query.uid as string | undefined;

		if (!provider) {
			res.status(400).send("Missing provider parameter");
			return;
		}

		// For link mode, uid is required
		if (mode === 'link' && !linkingUserId) {
			res.status(400).send("Missing uid parameter for link mode");
			return;
		}

		const callbackUrl = `https://betterkeep.app/oauth/callback`;

		// Create state with provider info for callback
		const state: OAuthState = { provider, redirect, mode, linkingUserId };
		const stateStr = Buffer.from(JSON.stringify(state)).toString("base64url");

		let authUrl: string;

		switch (provider) {
			case "facebook":
				authUrl =
					`https://www.facebook.com/v18.0/dialog/oauth?` +
					`client_id=${facebookAppId.value()}` +
					`&redirect_uri=${encodeURIComponent(callbackUrl)}` +
					`&state=${stateStr}` +
					`&scope=email,public_profile`;
				break;

			case "github":
				authUrl =
					`https://github.com/login/oauth/authorize?` +
					`client_id=${githubClientId.value()}` +
					`&redirect_uri=${encodeURIComponent(callbackUrl)}` +
					`&state=${stateStr}` +
					`&scope=read:user,user:email`;
				break;

			case "twitter": {
				// Twitter uses OAuth 2.0 PKCE flow
				// Generate code verifier and challenge
				const codeVerifier = crypto.randomBytes(32).toString("base64url");
				const codeChallenge = crypto
					.createHash("sha256")
					.update(codeVerifier)
					.digest("base64url");

				// Store code verifier in state (it's URL-safe base64)
				const twitterState: OAuthState = {
					provider,
					redirect,
					nonce: codeVerifier,
					mode,
					linkingUserId,
				};
				const twitterStateStr = Buffer.from(
					JSON.stringify(twitterState),
				).toString("base64url");

				authUrl =
					`https://twitter.com/i/oauth2/authorize?` +
					`client_id=${twitterClientId.value()}` +
					`&redirect_uri=${encodeURIComponent(callbackUrl)}` +
					`&state=${twitterStateStr}` +
					`&scope=tweet.read%20users.read%20offline.access` +
					`&response_type=code` +
					`&code_challenge=${codeChallenge}` +
					`&code_challenge_method=S256`;
				break;
			}

			default:
				res.status(400).send(`Unknown provider: ${provider}`);
				return;
		}

		res.redirect(authUrl);
	},
);

/**
 * OAuth callback - exchanges code for tokens and creates Firebase user
 * This is called by OAuth providers after user authorizes
 */
export const oauthCallback = onRequest(
	{
		secrets: [
			facebookAppId,
			facebookAppSecret,
			githubClientId,
			githubClientSecret,
			twitterClientId,
			twitterClientSecret,
		],
		cors: true,
	},
	async (req, res) => {
		const code = req.query.code as string;
		const stateStr = req.query.state as string;
		const error = req.query.error as string;

		// Helper function to send error based on mode (popup vs redirect)
		const sendError = (errorMsg: string, state?: OAuthState) => {
			const isPopup = state?.redirect === "popup";
			const htmlSafeError = errorMsg
				.replace(/&/g, "&amp;")
				.replace(/</g, "&lt;")
				.replace(/>/g, "&gt;")
				.replace(/"/g, "&quot;");
			const jsSafeError = errorMsg
				.replace(/\\/g, "\\\\")
				.replace(/'/g, "\\'")
				.replace(/\n/g, "\\n");

			if (isPopup) {
				res.send(`
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Sign In Failed - Better Keep</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0;
    }
    .container {
      background: white;
      border-radius: 16px;
      padding: 40px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
      max-width: 400px;
    }
    h1 { color: #D32F2F; margin-bottom: 16px; }
    p { color: #666; }
  </style>
</head>
<body>
  <div class="container">
    <h1>✗ Sign In Failed</h1>
    <p>${htmlSafeError}</p>
  </div>
  <script>
    if (window.opener) {
      var attempts = 0;
      var maxAttempts = 20;
      var interval = setInterval(function() {
        attempts++;
        console.log('Sending oauth_error message, attempt ' + attempts);
        window.opener.postMessage({
          type: 'oauth_error',
          error: '${jsSafeError}'
        }, '*');
        if (attempts >= maxAttempts) {
          clearInterval(interval);
        }
      }, 500);
      window.addEventListener('message', function(event) {
        if (event.data && event.data.type === 'oauth_close') {
          clearInterval(interval);
          window.close();
        }
      });
    }
  </script>
</body>
</html>
				`);
			} else if (state?.redirect && state.redirect !== "popup") {
				// Mobile deep link mode
				res.redirect(
					`${state.redirect}://auth?error=${encodeURIComponent(errorMsg)}`,
				);
			} else {
				// Fallback to web page
				res.redirect(
					`https://betterkeep.app/auth.html?error=${encodeURIComponent(errorMsg)}`,
				);
			}
		};

		// Try to parse state first to determine mode
		let state: OAuthState | undefined;
		if (stateStr) {
			try {
				state = JSON.parse(Buffer.from(stateStr, "base64url").toString());
			} catch {
				// State parsing failed, will use fallback error handling
			}
		}

		// Handle OAuth errors (user denied, etc.)
		if (error) {
			const errorDesc =
				(req.query.error_description as string) || "Authorization failed";
			sendError(errorDesc, state);
			return;
		}

		if (!code || !stateStr) {
			sendError("Missing authorization code", state);
			return;
		}

		if (!state) {
			sendError("Invalid state");
			return;
		}

		const callbackUrl = `https://betterkeep.app/oauth/callback`;

		try {
			let userInfo: { id: string; email?: string; name?: string; photo?: string };

			switch (state.provider) {
				case "facebook": {
					// Exchange code for access token
					const tokenRes = await fetch(
						`https://graph.facebook.com/v18.0/oauth/access_token?` +
							`client_id=${facebookAppId.value()}` +
							`&client_secret=${facebookAppSecret.value()}` +
							`&redirect_uri=${encodeURIComponent(callbackUrl)}` +
							`&code=${code}`,
					);
					const tokenData = (await tokenRes.json()) as {
						access_token?: string;
						error?: { message: string };
					};

					if (!tokenData.access_token) {
						throw new Error(
							tokenData.error?.message || "Failed to get access token",
						);
					}

					// Get user info
					const userRes = await fetch(
						`https://graph.facebook.com/me?fields=id,name,email,picture.type(large)&access_token=${tokenData.access_token}`,
					);
					const userData = (await userRes.json()) as {
						id: string;
						name?: string;
						email?: string;
						picture?: { data?: { url?: string } };
					};

					userInfo = {
						id: userData.id,
						email: userData.email,
						name: userData.name,
						photo: userData.picture?.data?.url,
					};
					break;
				}

				case "github": {
					// Exchange code for access token
					const tokenRes = await fetch(
						`https://github.com/login/oauth/access_token`,
						{
							method: "POST",
							headers: {
								Accept: "application/json",
								"Content-Type": "application/json",
							},
							body: JSON.stringify({
								client_id: githubClientId.value(),
								client_secret: githubClientSecret.value(),
								code,
								redirect_uri: callbackUrl,
							}),
						},
					);
					const tokenData = (await tokenRes.json()) as {
						access_token?: string;
						error?: string;
					};

					if (!tokenData.access_token) {
						throw new Error(tokenData.error || "Failed to get access token");
					}

					// Get user info
					const userRes = await fetch(`https://api.github.com/user`, {
						headers: {
							Authorization: `Bearer ${tokenData.access_token}`,
							Accept: "application/vnd.github.v3+json",
						},
					});
					const userData = (await userRes.json()) as {
						id: number;
						name?: string;
						email?: string;
						avatar_url?: string;
					};

					// GitHub may not return email in user endpoint, need to fetch separately
					let email = userData.email;
					if (!email) {
						const emailRes = await fetch(`https://api.github.com/user/emails`, {
							headers: {
								Authorization: `Bearer ${tokenData.access_token}`,
								Accept: "application/vnd.github.v3+json",
							},
						});
						const emails = (await emailRes.json()) as Array<{
							email: string;
							primary: boolean;
							verified: boolean;
						}>;
						const primaryEmail = emails.find((e) => e.primary && e.verified);
						email = primaryEmail?.email || emails[0]?.email;
					}

					userInfo = {
						id: userData.id.toString(),
						email,
						name: userData.name,
						photo: userData.avatar_url,
					};
					break;
				}

				case "twitter": {
					// Exchange code for access token using PKCE
					const codeVerifier = state.nonce;
					if (!codeVerifier) {
						throw new Error("Missing code verifier");
					}

					const basicAuth = Buffer.from(
						`${twitterClientId.value()}:${twitterClientSecret.value()}`,
					).toString("base64");

					const tokenRes = await fetch(
						`https://api.twitter.com/2/oauth2/token`,
						{
							method: "POST",
							headers: {
								"Content-Type": "application/x-www-form-urlencoded",
								Authorization: `Basic ${basicAuth}`,
							},
							body: new URLSearchParams({
								grant_type: "authorization_code",
								code,
								redirect_uri: callbackUrl,
								code_verifier: codeVerifier,
							}),
						},
					);
					const tokenData = (await tokenRes.json()) as {
						access_token?: string;
						error?: string;
					};

					if (!tokenData.access_token) {
						throw new Error(tokenData.error || "Failed to get access token");
					}

					// Get user info
					const userRes = await fetch(
						`https://api.twitter.com/2/users/me?user.fields=id,name,profile_image_url`,
						{
							headers: {
								Authorization: `Bearer ${tokenData.access_token}`,
							},
						},
					);
					const userDataResponse = (await userRes.json()) as {
						data?: {
							id: string;
							name?: string;
							username?: string;
							profile_image_url?: string;
						};
					};
					const userData = userDataResponse.data;

					if (!userData) {
						throw new Error("Failed to get user info from Twitter");
					}

					userInfo = {
						id: userData.id,
						name: userData.name || userData.username,
						photo: userData.profile_image_url?.replace("_normal", ""),
						// Twitter doesn't provide email in basic scope
					};
					break;
				}

				default:
					throw new Error(`Unknown provider: ${state.provider}`);
			}

			// Handle LINK mode differently from SIGNIN mode
			if (state.mode === 'link' && state.linkingUserId) {
				// LINK MODE: User is already signed in, just link the provider
				
				// Verify the linking user exists
				try {
					await auth.getUser(state.linkingUserId);
				} catch {
					throw new Error('User not found. Please sign in again.');
				}

				// SECURITY: Verify OTP was verified before allowing link
				// This prevents bypassing OTP by directly calling OAuth URL
				const otpRef = db.collection("users").doc(state.linkingUserId)
					.collection("otpVerification").doc("accountLink");
				const otpDoc = await otpRef.get();
				
				if (!otpDoc.exists) {
					throw new Error('Account link not authorized. Please verify your email first.');
				}
				
				const otpData = otpDoc.data();
				if (!otpData?.verified) {
					throw new Error('Account link not authorized. Please complete email verification first.');
				}
				
				// Check OTP was verified for the same provider
				if (otpData.provider !== `${state.provider}.com`) {
					throw new Error('Provider mismatch. Please start the linking process again.');
				}
				
				// Check link token hasn't expired (2 minute window after OTP verification)
				const now = Timestamp.now();
				if (otpData.linkTokenExpires && otpData.linkTokenExpires.toMillis() < now.toMillis()) {
					await otpRef.delete();
					throw new Error('Link authorization expired. Please verify your email again.');
				}

				// Check if this OAuth account is already linked to a different user
				if (userInfo.email) {
					try {
						const existingUser = await auth.getUserByEmail(userInfo.email);
						if (existingUser.uid !== state.linkingUserId) {
							throw new Error(
								`This ${state.provider} account is already associated with a different user. ` +
								`Please use a different ${state.provider} account.`
							);
						}
					} catch (e) {
						// If error is not "user not found", it's our custom error - rethrow
						if (e instanceof Error && !e.message.includes('no user record')) {
							throw e;
						}
						// User not found by email is fine - it means OAuth account is not linked elsewhere
					}
				}

				// Check if provider is already linked to this user
				const userDoc = await db.collection("users").doc(state.linkingUserId).get();
				const linkedProviders = userDoc.data()?.linkedProviders || {};
				const existingProviderData = linkedProviders[state.provider];
				
				if (existingProviderData?.providerUid && existingProviderData.providerUid !== userInfo.id) {
					throw new Error(
						`A different ${state.provider} account is already linked. ` +
						`Please unlink it first before linking a new one.`
					);
				}

				// Store the linked provider in Firestore
				await db.collection("users").doc(state.linkingUserId).set({
					linkedProviders: {
						[state.provider]: {
							providerUid: userInfo.id,
							linkedAt: FieldValue.serverTimestamp(),
							linkedVia: 'oauth_link',
						}
					}
				}, { merge: true });

				// Log the successful link for audit
				await db.collection("users").doc(state.linkingUserId).collection("auditLog").add({
					action: "account_linked",
					provider: state.provider,
					providerUid: userInfo.id,
					timestamp: FieldValue.serverTimestamp(),
					success: true,
				});

				// Clean up OTP verification doc after successful link
				await otpRef.delete();

				console.log(
					`Account linked via OAuth for user ${state.linkingUserId}, provider ${state.provider}`,
				);

				// Return success (no token needed - user is already signed in)
				if (state.redirect === 'popup') {
					res.send(`
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Account Linked - Better Keep</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0;
    }
    .container {
      background: white;
      border-radius: 16px;
      padding: 40px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
      max-width: 400px;
    }
    h1 { color: #2E7D32; margin-bottom: 16px; }
    p { color: #666; }
  </style>
</head>
<body>
  <div class="container">
    <h1>✓ Account Linked</h1>
    <p id="status">Completing...</p>
  </div>
  <script>
    if (window.opener) {
      var attempts = 0;
      var maxAttempts = 20;
      var interval = setInterval(function() {
        attempts++;
        console.log('Sending oauth_link_success message, attempt ' + attempts);
        window.opener.postMessage({
          type: 'oauth_link_success',
          provider: '${state.provider}'
        }, '*');
        if (attempts >= maxAttempts) {
          clearInterval(interval);
          document.getElementById('status').textContent = 'Please close this window manually.';
        }
      }, 500);
      window.addEventListener('message', function(event) {
        if (event.data && event.data.type === 'oauth_close') {
          clearInterval(interval);
          window.close();
        }
      });
    } else {
      document.querySelector('.container').innerHTML = 
        '<h1>✓ Account Linked</h1>' +
        '<p>Please close this window and return to Better Keep.</p>';
    }
  </script>
</body>
</html>
					`);
				} else {
					// Mobile deep link mode
					const redirectUrl = `${state.redirect}://auth?linked=true&provider=${state.provider}`;
					res.redirect(redirectUrl);
				}
				return;
			}

			// SIGNIN MODE: Find or create Firebase user
			let firebaseUser: admin.auth.UserRecord;

			// Helper to mask email for security in error messages
			const maskEmail = (email: string): string => {
				const [localPart, domain] = email.split("@");
				const maskedLocal =
					localPart.length <= 2
						? localPart[0] + "*"
						: localPart.slice(0, 2) + "*".repeat(Math.min(localPart.length - 2, 5));
				const domainParts = domain.split(".");
				const maskedDomain = domainParts
					.map((part, i) =>
						i === domainParts.length - 1
							? part // Keep TLD visible (.com, .org)
							: part.length <= 2
								? part[0] + "*"
								: part.slice(0, 2) + "*".repeat(Math.min(part.length - 2, 3))
					)
					.join(".");
				return `${maskedLocal}@${maskedDomain}`;
			};

			// Check if user exists by email
			let existingUser: admin.auth.UserRecord | null = null;
			if (userInfo.email) {
				try {
					existingUser = await auth.getUserByEmail(userInfo.email);
				} catch {
					existingUser = null;
				}
			}

			if (existingUser) {
				// User exists - check if they can login with this provider
				// Check 1: Firebase Auth's providerData (native SDK logins)
				const providerDomain = `${state.provider}.com`;
				const hasProviderInAuth = existingUser.providerData?.some(
					(p) => p.providerId === providerDomain
				);

				// Check 2: User document's linkedProviders (our custom linking)
				const userDoc = await db.collection("users").doc(existingUser.uid).get();
				const linkedProviders = userDoc.data()?.linkedProviders || {};
				const providerData = linkedProviders[state.provider];
				// Allow if: provider exists in linkedProviders AND (no providerUid OR providerUid matches)
				const hasProviderLinked = providerData && 
					(!providerData.providerUid || providerData.providerUid === userInfo.id);

				// Check 3: User's original signup provider
				const signupProvider = userDoc.data()?.provider;
				const isOriginalProvider = signupProvider === state.provider;

				if (hasProviderInAuth || hasProviderLinked || isOriginalProvider) {
					// Allowed - user has this provider linked or signed up with it
					firebaseUser = existingUser;

					// Update linkedProviders with providerUid if missing (first login after OTP linking)
					if (!providerData?.providerUid) {
						await db.collection("users").doc(existingUser.uid).set({
							linkedProviders: {
								[state.provider]: {
									providerUid: userInfo.id,
									linkedAt: providerData?.linkedAt || FieldValue.serverTimestamp(),
									linkedVia: providerData?.linkedVia || 'oauth_login',
								}
							}
						}, { merge: true });
					}
				} else {
					// SECURITY: Email exists but this provider is NOT linked
					throw new Error(
						`An account with email ${maskEmail(userInfo.email!)} already exists. ` +
						`Please sign in with your original login method, ` +
						`then link ${state.provider} from your account settings.`
					);
				}
			} else {
				// New user - create account
				if (userInfo.email) {
					firebaseUser = await auth.createUser({
						email: userInfo.email,
						displayName: userInfo.name,
						photoURL: userInfo.photo,
					});
				} else {
					// No email (e.g., Twitter) - create user without email
					firebaseUser = await auth.createUser({
						displayName: userInfo.name,
						photoURL: userInfo.photo,
					});
				}

				// Store provider in user document
				await db.collection("users").doc(firebaseUser.uid).set({
					email: userInfo.email || null,
					displayName: userInfo.name,
					photoURL: userInfo.photo,
					provider: state.provider,
					linkedProviders: {
						[state.provider]: {
							providerUid: userInfo.id,
							linkedAt: FieldValue.serverTimestamp(),
						}
					},
					createdAt: FieldValue.serverTimestamp(),
					lastSeen: FieldValue.serverTimestamp(),
				}, { merge: true });

				// Grant trial for new users (blocking functions don't trigger for custom token auth)
				// This replicates the logic from grantTrialOnFirstSignIn
				if (TRIAL_ENABLED) {
					const email = userInfo.email?.trim()?.toLowerCase() || null;
					const emailKey = email || `no-email-${firebaseUser.uid}`;
					const trialRef = db.collection("trialUsage").doc(emailKey);
					const subscriptionRef = db.collection("users").doc(firebaseUser.uid)
						.collection("subscription").doc("status");

					// Check if email already used trial (for users who deleted and re-registered)
					const trialDoc = await trialRef.get();
					if (!trialDoc.exists) {
						// Calculate trial expiry
						const trialExpiresAt = new Date();
						if (DEBUG_TRIAL_MINUTES !== null) {
							trialExpiresAt.setMinutes(trialExpiresAt.getMinutes() + DEBUG_TRIAL_MINUTES);
						} else {
							trialExpiresAt.setDate(trialExpiresAt.getDate() + TRIAL_DAYS);
						}

						console.log(`Granting trial to new OAuth user ${firebaseUser.uid}, expires ${trialExpiresAt.toISOString()}`);

						// Write trial data in parallel
						await Promise.all([
							// Mark trial as used
							trialRef.set({
								userId: firebaseUser.uid,
								email: email || "none",
								trialStartedAt: Timestamp.now(),
								trialExpiresAt: Timestamp.fromDate(trialExpiresAt),
								createdAt: Timestamp.now(),
							}),
							// Create trial subscription
							subscriptionRef.set({
								plan: "pro",
								source: "trial",
								expiryDate: Timestamp.fromDate(trialExpiresAt),
								billingPeriod: "trial",
								willAutoRenew: false,
								status: "trial",
								trialStartedAt: Timestamp.now(),
								updatedAt: Timestamp.now(),
							}),
						]);

						// Set custom claims for trial
						await auth.setCustomUserClaims(firebaseUser.uid, {
							plan: "pro",
							planExpiresAt: trialExpiresAt.getTime(),
						});

						console.log(`Trial granted to OAuth user ${firebaseUser.uid}`);

						// Send trial welcome email in background (don't block OAuth flow)
						if (email) {
							sendTrialWelcomeEmail(
								email,
								userInfo.name || "there",
								trialExpiresAt,
							).catch((e) => console.error(`Trial email send failed: ${e}`));
						}
					} else {
						console.log(`Email ${emailKey} already used trial, skipping for OAuth user ${firebaseUser.uid}`);
					}
				}
			}

			// Create custom token
			const customToken = await auth.createCustomToken(firebaseUser.uid);

			// Handle different redirect modes
			if (state.redirect === 'popup') {
				// Web popup mode: Use postMessage to send token back to opener
				res.send(`
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sign In Successful - Better Keep</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0;
    }
    .container {
      background: white;
      border-radius: 16px;
      padding: 40px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
      max-width: 400px;
    }
    h1 { color: #2E7D32; margin-bottom: 16px; }
    p { color: #666; }
  </style>
</head>
<body>
  <div class="container">
    <h1>✓ Sign In Successful</h1>
    <p id="status">Completing sign-in...</p>
  </div>
  <script>
    // Send token to opener window via postMessage
    if (window.opener) {
      // Send message repeatedly until parent acknowledges or timeout
      var attempts = 0;
      var maxAttempts = 20; // 10 seconds max
      var interval = setInterval(function() {
        attempts++;
        console.log('Sending oauth_success message, attempt ' + attempts);
        window.opener.postMessage({
          type: 'oauth_success',
          token: '${customToken}',
          provider: '${state.provider}'
        }, '*'); // Use * to allow any origin since Flutter web might be on localhost
        
        if (attempts >= maxAttempts) {
          clearInterval(interval);
          document.getElementById('status').textContent = 'Please close this window manually.';
        }
      }, 500);
      
      // Listen for close command from parent
      window.addEventListener('message', function(event) {
        if (event.data && event.data.type === 'oauth_close') {
          console.log('Received close command from parent');
          clearInterval(interval);
          window.close();
        }
      });
    } else {
      // Fallback: Show manual instructions
      document.querySelector('.container').innerHTML = 
        '<h1>✓ Sign In Successful</h1>' +
        '<p>Please close this window and return to Better Keep.</p>';
    }
  </script>
</body>
</html>
				`);
			} else {
				// Mobile deep link mode: Redirect to app
				const redirectUrl = `${state.redirect}://auth?token=${encodeURIComponent(customToken)}&provider=${state.provider}`;

				// Send HTML that tries to redirect and shows a button as fallback
				res.send(`
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Sign In Successful - Better Keep</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0;
    }
    .container {
      background: white;
      border-radius: 16px;
      padding: 40px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
      max-width: 400px;
    }
    h1 { color: #2E7D32; margin-bottom: 16px; }
    p { color: #666; margin-bottom: 16px; }
    .hint { color: #999; font-size: 14px; margin-top: 16px; }
    .btn {
      background: #6750A4;
      color: white;
      border: none;
      padding: 14px 28px;
      border-radius: 8px;
      font-size: 16px;
      cursor: pointer;
      text-decoration: none;
      display: inline-block;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>✓ Sign In Successful</h1>
    <p>Redirecting back to Better Keep...</p>
    <a href="${redirectUrl}" class="btn">Open Better Keep</a>
    <p class="hint">You can close this tab after the app opens.</p>
  </div>
  <script>
    window.location.href = "${redirectUrl}";
  </script>
</body>
</html>
				`);
			}
		} catch (e) {
			console.error("OAuth callback error:", e);
			const errorMsg =
				e instanceof Error ? e.message : "Authentication failed";
			
			// Escape error message for HTML and JavaScript
			const htmlSafeError = errorMsg.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
			const jsSafeError = errorMsg.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/"/g, '\\"');
			
			// Try to get state from query to determine if this was a popup request
			const stateParam = req.query.state as string | undefined;
			let isPopup = false;
			if (stateParam) {
				try {
					const state = JSON.parse(Buffer.from(stateParam, 'base64').toString('utf-8'));
					isPopup = state.redirect === 'popup';
				} catch {
					// Ignore parse errors
				}
			}
			
			if (isPopup) {
				// Send error via postMessage
				res.send(`
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Sign In Failed - Better Keep</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0;
    }
    .container {
      background: white;
      border-radius: 16px;
      padding: 40px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
      max-width: 400px;
    }
    h1 { color: #D32F2F; margin-bottom: 16px; }
    p { color: #666; }
  </style>
</head>
<body>
  <div class="container">
    <h1>✗ Sign In Failed</h1>
    <p>${htmlSafeError}</p>
  </div>
  <script>
    if (window.opener) {
      // Send error message repeatedly until parent acknowledges or timeout
      var attempts = 0;
      var maxAttempts = 20; // 10 seconds max
      var interval = setInterval(function() {
        attempts++;
        console.log('Sending oauth_error message, attempt ' + attempts);
        window.opener.postMessage({
          type: 'oauth_error',
          error: '${jsSafeError}'
        }, '*'); // Use * to allow any origin since Flutter web might be on localhost
        
        if (attempts >= maxAttempts) {
          clearInterval(interval);
        }
      }, 500);
      
      // Listen for close command from parent
      window.addEventListener('message', function(event) {
        if (event.data && event.data.type === 'oauth_close') {
          console.log('Received close command from parent');
          clearInterval(interval);
          window.close();
        }
      });
    }
  </script>
</body>
</html>
				`);
			} else {
				res.redirect(
					`https://betterkeep.app/auth.html?error=${encodeURIComponent(errorMsg)}`,
				);
			}
		}
	},
);

/**
 * HTTP Callable function to send OTP for account deletion verification
 */
export const sendDeletionOtp = onCall(
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

			// Store OTP in Firestore
			await userRef.collection("otpVerification").doc("deletion").set({
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

			await sendEmail(transporter, mailOptions);

			// Mask email for display
			const maskedEmail = email.replace(
				/(.{2})(.*)(@.*)/,
				(_, start, middle, end) =>
					start + "*".repeat(Math.min(middle.length, 5)) + end,
			);

			console.log(`Sent deletion OTP to user ${userId} (${maskedEmail})`);

			return {
				success: true,
				message: "Verification code sent",
				email: maskedEmail,
				expiresIn: 600, // 10 minutes in seconds
			};
		} catch (error) {
			console.error(`Error sending OTP to ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to send verification code");
		}
	},
);

/**
 * HTTP Callable function to verify OTP for account deletion
 */
export const verifyDeletionOtp = onCall(
	async (request: CallableRequest<{ otp: string }>) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to verify OTP",
			);
		}

		const userId = request.auth.uid;
		const providedOtp = request.data?.otp;

		if (!providedOtp || typeof providedOtp !== "string") {
			throw new HttpsError("invalid-argument", "OTP is required");
		}

		try {
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

			// Check if expired
			if (otpData.expiresAt.toMillis() < now.toMillis()) {
				await otpRef.delete();
				throw new HttpsError(
					"deadline-exceeded",
					"Verification code has expired. Please request a new one.",
				);
			}

			// Check attempts (max 5)
			if (otpData.attempts >= 5) {
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

				const remainingAttempts = 4 - otpData.attempts;
				throw new HttpsError(
					"permission-denied",
					`Invalid code. ${remainingAttempts} attempt${
						remainingAttempts !== 1 ? "s" : ""
					} remaining.`,
				);
			}

			// OTP is valid - create a verification token that's valid for 5 minutes
			const verificationToken = Timestamp.fromMillis(
				Date.now() + 5 * 60 * 1000,
			);

			// Store verification status
			await otpRef.set({
				verified: true,
				verifiedAt: now,
				verificationExpires: verificationToken,
			});

			console.log(`OTP verified for user ${userId}`);

			return {
				success: true,
				message: "Verification successful",
				tokenExpiresIn: 300, // 5 minutes to complete deletion
			};
		} catch (error) {
			console.error(`Error verifying OTP for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to verify code");
		}
	},
);

// ============================================================
// EMAIL VERIFICATION OTP
// ============================================================

/**
 * HTTP Callable function to send OTP for email verification.
 * Used during signup when user needs to verify their email address.
 */
export const sendEmailVerificationOtp = onCall(
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

			console.log(`Sent email verification OTP to user ${userId} (${maskedEmail})`);

			return {
				success: true,
				message: "Verification code sent",
				email: maskedEmail,
				expiresIn: 600, // 10 minutes in seconds
			};
		} catch (error) {
			console.error(`Error sending email verification OTP to ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to send verification code");
		}
	},
);

/**
 * HTTP Callable function to verify OTP and mark email as verified.
 */
export const verifyEmailVerificationOtp = onCall(
	async (request: CallableRequest<{ otp: string }>) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to verify OTP",
			);
		}

		const userId = request.auth.uid;
		const providedOtp = request.data?.otp;

		if (!providedOtp || typeof providedOtp !== "string") {
			throw new HttpsError("invalid-argument", "OTP is required");
		}

		try {
			const otpRef = db
				.collection("users")
				.doc(userId)
				.collection("otpVerification")
				.doc("emailVerification");
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

			// Check if expired
			if (otpData.expiresAt.toMillis() < now.toMillis()) {
				await otpRef.delete();
				throw new HttpsError(
					"deadline-exceeded",
					"Verification code has expired. Please request a new one.",
				);
			}

			// Check attempts (max 5)
			if (otpData.attempts >= 5) {
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

				const remainingAttempts = 4 - otpData.attempts;
				throw new HttpsError(
					"permission-denied",
					`Invalid code. ${remainingAttempts} attempt${
						remainingAttempts !== 1 ? "s" : ""
					} remaining.`,
				);
			}

			// OTP is valid - mark email as verified in Firebase Auth
			await auth.updateUser(userId, {
				emailVerified: true,
			});

			// Clean up OTP document
			await otpRef.delete();

			console.log(`Email verified for user ${userId}`);

			return {
				success: true,
				message: "Email verified successfully",
			};
		} catch (error) {
			console.error(`Error verifying email OTP for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to verify code");
		}
	},
);

/**
 * HTTP Callable function to send OTP for "start fresh" account reset verification.
 * This is used when a user has no approved devices and wants to reset their account.
 */
export const sendStartFreshOtp = onCall(
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

/**
 * HTTP Callable function to verify OTP and perform "start fresh" account reset.
 * This clears all devices from Firestore, allowing the user to start fresh.
 * REQUIRES: Valid OTP must be provided in the same request (atomic verification)
 */
export const startFreshWithOtp = onCall(
	async (request: CallableRequest<{ otp: string }>) => {
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
			console.log(`Start fresh OTP verified for user ${userId}`);

			// Delete all devices - this allows the user to start fresh
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

			// Delete any pending approval requests
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

			// Clear recovery key if exists
			await userRef
				.update({
					recoveryKey: admin.firestore.FieldValue.delete(),
				})
				.catch(() => {
					// User doc might not have this field, ignore error
				});

			console.log(`Start fresh completed for user ${userId}`);

			return {
				success: true,
				message:
					"Account reset successful. You can now set up your account fresh.",
			};
		} catch (error) {
			console.error(`Error during start fresh for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to reset account");
		}
	},
);

// ============================================================
// ACCOUNT LINKING - OTP-based secure provider linking
// ============================================================

/**
 * Allowed provider IDs for account linking
 */
const ALLOWED_PROVIDERS = [
	"google.com",
	"facebook.com",
	"github.com",
	"twitter.com",
] as const;

type AllowedProvider = (typeof ALLOWED_PROVIDERS)[number];

/**
 * HTTP Callable function to request OTP for account linking
 * Sends a 6-digit OTP to the user's primary email to verify they own the account
 */
export const requestAccountLinkOtp = onCall(
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
		if (
			!provider ||
			!ALLOWED_PROVIDERS.includes(provider as AllowedProvider)
		) {
			throw new HttpsError(
				"invalid-argument",
				`Invalid provider. Allowed: ${ALLOWED_PROVIDERS.join(", ")}`,
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

			// Get provider display name
			const providerNames: Record<string, string> = {
				"google.com": "Google",
				"facebook.com": "Facebook",
				"github.com": "GitHub",
				"twitter.com": "Twitter/X",
			};
			const providerName = providerNames[provider] || provider;

			// Send email
			const transporter = getEmailTransporter(emailPassword.value());
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

			await sendEmail(transporter, mailOptions);

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

/**
 * HTTP Callable function to verify OTP for account linking
 * Returns a short-lived link token that must be used within 2 minutes
 */
export const verifyAccountLinkOtp = onCall(
	async (request: CallableRequest<{ otp: string; provider: string }>) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to verify OTP",
			);
		}

		const userId = request.auth.uid;
		const providedOtp = request.data?.otp;
		const provider = request.data?.provider;

		if (!providedOtp || typeof providedOtp !== "string") {
			throw new HttpsError("invalid-argument", "Verification code is required");
		}

		if (
			!provider ||
			!ALLOWED_PROVIDERS.includes(provider as AllowedProvider)
		) {
			throw new HttpsError("invalid-argument", "Invalid provider");
		}

		try {
			const userRef = db.collection("users").doc(userId);
			const otpRef = userRef.collection("otpVerification").doc("accountLink");
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

			// Check if expired
			if (otpData.expiresAt.toMillis() < now.toMillis()) {
				await otpRef.delete();
				throw new HttpsError(
					"deadline-exceeded",
					"Verification code has expired. Please request a new one.",
				);
			}

			// Check provider matches
			if (otpData.provider !== provider) {
				throw new HttpsError(
					"invalid-argument",
					"Provider mismatch. Please request a new code for this provider.",
				);
			}

			// Check attempts (max 5)
			if (otpData.attempts >= 5) {
				await otpRef.delete();
				throw new HttpsError(
					"resource-exhausted",
					"Too many attempts. Please request a new code.",
				);
			}

			// Verify OTP by comparing hashes
			const providedOtpHash = crypto
				.createHash("sha256")
				.update(providedOtp)
				.digest("hex");

			if (otpData.otpHash !== providedOtpHash) {
				await otpRef.update({
					attempts: admin.firestore.FieldValue.increment(1),
				});

				const remainingAttempts = 4 - otpData.attempts;
				throw new HttpsError(
					"permission-denied",
					`Invalid code. ${remainingAttempts} attempt${
						remainingAttempts !== 1 ? "s" : ""
					} remaining.`,
				);
			}

			// OTP verified! Generate a one-time link token
			const linkToken = crypto.randomBytes(32).toString("hex");
			const linkTokenHash = crypto
				.createHash("sha256")
				.update(linkToken)
				.digest("hex");
			const linkTokenExpires = Timestamp.fromMillis(
				Date.now() + 2 * 60 * 1000, // 2 minutes to complete OAuth
			);

			// Store verified status with link token
			await otpRef.set({
				verified: true,
				verifiedAt: now,
				linkTokenHash: linkTokenHash,
				linkTokenExpires: linkTokenExpires,
				provider: provider,
			});

			console.log(`Account link OTP verified for user ${userId}, provider ${provider}`);

			return {
				success: true,
				message: "Verification successful. Complete the linking now.",
				linkToken: linkToken,
				provider: provider,
				tokenExpiresIn: 120, // 2 minutes to complete OAuth
			};
		} catch (error) {
			console.error(
				`Error verifying account link OTP for ${userId}:`,
				error,
			);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to verify code");
		}
	},
);

/**
 * HTTP Callable function to confirm account link after OAuth
 * Validates the link token is still valid (proves OTP was verified)
 */
export const confirmAccountLink = onCall(
	async (
		request: CallableRequest<{ linkToken: string; provider: string }>,
	) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to confirm account link",
			);
		}

		const userId = request.auth.uid;
		const linkToken = request.data?.linkToken;
		const provider = request.data?.provider;

		if (!linkToken || typeof linkToken !== "string") {
			throw new HttpsError("invalid-argument", "Link token is required");
		}

		if (
			!provider ||
			!ALLOWED_PROVIDERS.includes(provider as AllowedProvider)
		) {
			throw new HttpsError("invalid-argument", "Invalid provider");
		}

		try {
			const userRef = db.collection("users").doc(userId);
			const otpRef = userRef.collection("otpVerification").doc("accountLink");
			const otpDoc = await otpRef.get();

			if (!otpDoc.exists) {
				throw new HttpsError(
					"permission-denied",
					"No verified session found. Please start over.",
				);
			}

			const otpData = otpDoc.data();
			if (!otpData || !otpData.verified) {
				throw new HttpsError(
					"permission-denied",
					"OTP not verified. Please start over.",
				);
			}

			const now = Timestamp.now();

			// Check if link token expired
			if (
				otpData.linkTokenExpires &&
				otpData.linkTokenExpires.toMillis() < now.toMillis()
			) {
				await otpRef.delete();
				throw new HttpsError(
					"deadline-exceeded",
					"Link session expired. Please start over.",
				);
			}

			// Check provider matches
			if (otpData.provider !== provider) {
				throw new HttpsError(
					"invalid-argument",
					"Provider mismatch. Please start over.",
				);
			}

			// Verify link token
			const providedTokenHash = crypto
				.createHash("sha256")
				.update(linkToken)
				.digest("hex");

			if (otpData.linkTokenHash !== providedTokenHash) {
				await otpRef.delete();
				throw new HttpsError(
					"permission-denied",
					"Invalid link token. Please start over.",
				);
			}

			// Everything valid! Clean up OTP document
			await otpRef.delete();

			// Store the linked provider in user document
			// Note: We don't have providerUid here since linking is done client-side via Firebase SDK
			// The providerUid will be added on first login with this provider
			await userRef.set({
				linkedProviders: {
					[provider.replace('.com', '')]: {
						linkedAt: now,
						linkedVia: 'otp_verification',
					}
				}
			}, { merge: true });

			// Log the successful link for audit
			await userRef.collection("auditLog").add({
				action: "account_linked",
				provider: provider,
				timestamp: now,
				success: true,
			});

			console.log(
				`Account link confirmed for user ${userId}, provider ${provider}`,
			);

			return {
				success: true,
				message: "Account linked successfully!",
			};
		} catch (error) {
			console.error(
				`Error confirming account link for ${userId}:`,
				error,
			);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to confirm account link");
		}
	},
);

/**
 * Scheduled function that runs daily at 3:00 AM UTC
 * Cleans up pending device requests that are older than 24 hours.
 * This prevents clutter from abandoned device approval requests.
 */
export const cleanupExpiredPendingDevices = onSchedule(
	{
		schedule: "0 3 * * *", // Cron: every day at 3:00 AM UTC
		timeZone: "UTC",
	},
	async () => {
		const now = Timestamp.now();
		// Devices pending for more than 24 hours are considered expired
		const expirationThreshold = Timestamp.fromMillis(
			now.toMillis() - 24 * 60 * 60 * 1000, // 24 hours ago
		);

		console.log(
			`Cleaning up expired pending devices at ${now.toDate().toISOString()}`,
		);
		console.log(
			`Expiration threshold: ${expirationThreshold.toDate().toISOString()}`,
		);

		const results = {
			usersProcessed: 0,
			devicesDeleted: 0,
			errors: 0,
		};

		try {
			// Get all users
			const usersSnapshot = await db.collection("users").get();

			for (const userDoc of usersSnapshot.docs) {
				const userId = userDoc.id;

				try {
					// Get pending devices for this user
					const devicesRef = userDoc.ref.collection("devices");
					const pendingDevicesSnapshot = await devicesRef
						.where("status", "==", "pending")
						.get();

					if (pendingDevicesSnapshot.empty) continue;

					results.usersProcessed++;
					const batch = db.batch();
					let deletedCount = 0;

					for (const deviceDoc of pendingDevicesSnapshot.docs) {
						const data = deviceDoc.data();
						const createdAt = data.created_at;

						if (!createdAt) {
							// No created_at field - delete it (malformed data)
							batch.delete(deviceDoc.ref);
							deletedCount++;
							continue;
						}

						// Parse the ISO string date
						const createdDate = new Date(createdAt);
						const createdTimestamp = Timestamp.fromDate(createdDate);

						// Check if device is older than 24 hours
						if (createdTimestamp.toMillis() < expirationThreshold.toMillis()) {
							batch.delete(deviceDoc.ref);
							deletedCount++;
						}
					}

					if (deletedCount > 0) {
						await batch.commit();
						results.devicesDeleted += deletedCount;
						console.log(
							`Deleted ${deletedCount} expired pending devices for user ${userId}`,
						);
					}
				} catch (userError) {
					results.errors++;
					console.error(`Error processing user ${userId}:`, userError);
				}
			}

			console.log(
				`Cleanup complete: processed ${results.usersProcessed} users, ` +
					`deleted ${results.devicesDeleted} expired pending devices, ` +
					`${results.errors} errors`,
			);
		} catch (error) {
			console.error("Error during pending device cleanup:", error);
		}
	},
);

/**
 * Scheduled function that runs daily at 8:00 AM UTC
 * Sends reminder emails to users whose accounts will be deleted tomorrow.
 */
export const sendDeletionReminders = onSchedule(
	{
		schedule: "0 8 * * *", // Cron: every day at 8:00 AM UTC
		timeZone: "UTC",
		secrets: [emailPassword],
	},
	async () => {
		const now = Timestamp.now();

		console.log(
			`Processing deletion reminders at ${now.toDate().toISOString()}`,
		);

		// Query users whose reminder time has passed and haven't received reminder
		const snapshot = await db
			.collection("users")
			.where("scheduledDeletion.reminderAt", "<=", now)
			.where("scheduledDeletion.reminderSent", "==", false)
			.get();

		console.log(`Found ${snapshot.size} users to send reminders`);

		const results = {
			processed: 0,
			succeeded: 0,
			failed: 0,
		};

		for (const doc of snapshot.docs) {
			const userId = doc.id;
			const userData = doc.data();
			results.processed++;

			try {
				// Get user email
				const userRecord = await auth.getUser(userId);
				const email = userRecord.email;

				if (!email) {
					console.log(`No email for user ${userId}, skipping reminder`);
					continue;
				}

				const deleteAt = userData.scheduledDeletion?.deleteAt;
				if (!deleteAt) continue;

				const deleteDate = deleteAt.toDate().toLocaleDateString("en-US", {
					weekday: "long",
					year: "numeric",
					month: "long",
					day: "numeric",
				});

				const transporter = getEmailTransporter(emailPassword.value());
				const senderEmail = process.env.EMAIL_FROM;
				const senderName = process.env.EMAIL_NAME;

				const mailOptions = {
					from: `"${senderName}" <${senderEmail}>`,
					to: email,
					subject:
						"⚠️ Final Reminder: Account Deletion Tomorrow - Better Keep Notes",
					html: `
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
            </head>
            <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
              <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
                <div style="background: #d32f2f; color: white; padding: 16px; border-radius: 8px; text-align: center; margin-bottom: 24px;">
                  <h1 style="margin: 0; font-size: 24px;">⚠️ Final Reminder</h1>
                </div>
                <p style="color: #333; font-size: 16px; line-height: 1.5;">
                  Your Better Keep Notes account will be <strong>permanently deleted tomorrow</strong>.
                </p>
                <div style="background: #ffebee; border-radius: 8px; padding: 16px; margin: 24px 0; border: 2px solid #d32f2f;">
                  <p style="color: #c62828; font-size: 16px; margin: 0; font-weight: bold; text-align: center;">
                    Deletion Date: ${deleteDate}
                  </p>
                </div>
                <h2 style="color: #333; font-size: 18px; margin-top: 24px;">What will be deleted:</h2>
                <ul style="color: #666; font-size: 14px; line-height: 1.8; padding-left: 20px;">
                  <li>All your notes and their contents</li>
                  <li>All attachments and media files</li>
                  <li>All labels and organization data</li>
                  <li>Your account and login credentials</li>
                </ul>
                <div style="background: #e3f2fd; border-radius: 8px; padding: 20px; margin: 24px 0; text-align: center;">
                  <h2 style="color: #1565c0; font-size: 18px; margin-top: 0;">Want to keep your account?</h2>
                  <p style="color: #1976d2; font-size: 14px; margin-bottom: 0;">
                    Simply <strong>sign in to the Better Keep app</strong> before tomorrow and your account will be restored.
                  </p>
                </div>
                <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
                <p style="color: #999; font-size: 12px; text-align: center;">
                  If you have questions, contact us at support@betterkeep.app
                </p>
                <p style="color: #bbb; font-size: 11px; margin-top: 8px; text-align: center;">
                  Better Keep by Foxbiz Software Pvt. Ltd.
                </p>
              </div>
            </body>
            </html>
          `,
					text: `
⚠️ FINAL REMINDER - Account Deletion Tomorrow

Your Better Keep Notes account will be permanently deleted tomorrow.

Deletion Date: ${deleteDate}

What will be deleted:
- All your notes and their contents
- All attachments and media files
- All labels and organization data
- Your account and login credentials

Want to keep your account?
Simply sign in to the Better Keep app before tomorrow and your account will be restored.

This is an automated reminder. If you did not schedule this deletion, please sign in immediately or contact support.
          `,
				};

				await sendEmail(transporter, mailOptions);

				// Mark reminder as sent
				await doc.ref.update({
					"scheduledDeletion.reminderSent": true,
				});

				results.succeeded++;
				console.log(`✓ Sent reminder to user: ${userId}`);
			} catch (error) {
				results.failed++;
				console.error(`✗ Failed to send reminder to ${userId}: ${error}`);
			}
		}

		console.log(
			`Reminders complete: ${results.succeeded}/${results.processed} succeeded, ` +
				`${results.failed} failed`,
		);
	},
);

/**
 * Scheduled function that runs daily at 2:00 AM UTC
 * Processes users who have scheduled account deletion and whose 30-day
 * grace period has expired.
 */
export const processScheduledDeletions = onSchedule(
	{
		schedule: "0 2 * * *", // Cron: every day at 2:00 AM UTC
		timeZone: "UTC",
	},
	async () => {
		const now = Timestamp.now();

		console.log(
			`Processing scheduled deletions at ${now.toDate().toISOString()}`,
		);

		// Query users whose deletion time has passed
		const snapshot = await db
			.collection("users")
			.where("scheduledDeletion.deleteAt", "<=", now)
			.get();

		console.log(`Found ${snapshot.size} users scheduled for deletion`);

		const results = {
			processed: 0,
			succeeded: 0,
			failed: 0,
			errors: [] as string[],
		};

		for (const doc of snapshot.docs) {
			const userId = doc.id;
			results.processed++;

			try {
				await deleteUserCompletely(userId);
				results.succeeded++;
				console.log(`✓ Successfully deleted user: ${userId}`);
			} catch (error) {
				results.failed++;
				const errorMsg = `Failed to delete user ${userId}: ${error}`;
				results.errors.push(errorMsg);
				console.error(`✗ ${errorMsg}`);
			}
		}

		console.log(
			`Deletion complete: ${results.succeeded}/${results.processed} succeeded, ` +
				`${results.failed} failed`,
		);
	},
);

/**
 * Deletes all user data from Firestore, Storage, and Firebase Auth
 */
async function deleteUserCompletely(userId: string): Promise<void> {
	console.log(`Starting complete deletion for user: ${userId}`);

	const userRef = db.collection("users").doc(userId);

	// 1. Delete all known subcollections
	const subcollections = [
		"notes",
		"labels",
		"devices",
		"approvalRequests",
		"otpVerification",
	];

	for (const subcollection of subcollections) {
		console.log(`  Deleting subcollection: ${subcollection}`);
		await deleteCollection(userRef.collection(subcollection));
	}

	// 2. Delete user's files from Cloud Storage
	try {
		const bucket = storage.bucket();
		const [files] = await bucket.getFiles({ prefix: `users/${userId}/` });

		if (files.length > 0) {
			console.log(`  Deleting ${files.length} files from Storage`);
			for (const file of files) {
				await file.delete();
			}
		}
	} catch (error) {
		// Storage errors shouldn't stop the deletion process
		console.warn(`  Warning: Storage deletion issue for ${userId}:`, error);
	}

	// 3. Delete the user document itself
	console.log("  Deleting user document");
	await userRef.delete();

	// 4. Delete the Firebase Auth user
	try {
		await auth.deleteUser(userId);
		console.log("  Deleted Auth user");
	} catch (error: unknown) {
		// User might already be deleted from Auth, or never existed
		const authError = error as { code?: string };
		if (authError.code === "auth/user-not-found") {
			console.log("  Auth user already deleted or not found");
		} else {
			console.warn(`  Warning: Auth deletion issue for ${userId}:`, error);
		}
	}

	console.log(`  Complete deletion finished for user: ${userId}`);
}

/**
 * Recursively deletes all documents in a Firestore collection
 */
async function deleteCollection(
	collectionRef: admin.firestore.CollectionReference,
): Promise<void> {
	const batchSize = 500;

	const deleteQueryBatch = async (): Promise<void> => {
		const snapshot = await collectionRef.limit(batchSize).get();

		if (snapshot.empty) {
			return;
		}

		const batch = db.batch();
		for (const doc of snapshot.docs) {
			batch.delete(doc.ref);
		}
		await batch.commit();

		// If we deleted a full batch, there might be more documents
		if (snapshot.size === batchSize) {
			await deleteQueryBatch();
		}
	};

	await deleteQueryBatch();
}

/**
 * HTTP Callable function to cancel a scheduled deletion
 * Called when user signs back in before the 30-day grace period ends
 */
export const cancelScheduledDeletion = onCall(
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

/**
 * HTTP Callable function to schedule account deletion
 * Sets a 30-day grace period before permanent deletion
 * REQUIRES: Valid OTP must be provided in the same request (atomic verification)
 */
export const scheduleAccountDeletion = onCall(
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

// ============================================================================
// SUBSCRIPTION MANAGEMENT FUNCTIONS
// ============================================================================

interface VerifyPurchaseRequest {
	productId: string;
	purchaseToken: string;
	source: "play_store" | "app_store";
}

interface CheckSubscriptionRequest {
	purchaseToken?: string;
}

/**
 * Verify a purchase with Google Play and link it to the user's account.
 *
 * Security features:
 * - Verifies purchase with Google Play API
 * - Ensures one subscription = one account
 * - Handles app crash recovery
 * - Prevents fraud by server-side verification
 */
export const verifyPurchase = onCall(
	{ secrets: [googlePlayCredentials, emailPassword] },
	async (request: CallableRequest<VerifyPurchaseRequest>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be signed in");
		}

		const userId = request.auth.uid;
		const { productId, purchaseToken, source } = request.data;

		if (!productId || !purchaseToken || !source) {
			throw new HttpsError("invalid-argument", "Missing required fields");
		}

		console.log(
			`Verifying purchase for user ${userId}: ${productId} (${source})`,
		);

		try {
			let result: { valid: boolean; message: string; subscription?: object };

			if (source === "play_store") {
				result = await verifyGooglePlayPurchase(
					userId,
					productId,
					purchaseToken,
				);
			} else if (source === "app_store") {
				// TODO: Implement App Store verification
				throw new HttpsError(
					"unimplemented",
					"App Store verification not yet implemented",
				);
			} else {
				throw new HttpsError("invalid-argument", "Invalid source");
			}

			// Send welcome email if verification was successful
			if (result.valid) {
				await sendSubscriptionWelcomeEmail(userId, result.subscription);
			}

			return result;
		} catch (error) {
			console.error(`Error verifying purchase for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to verify purchase");
		}
	},
);

/**
 * Verify Google Play subscription purchase
 */
async function verifyGooglePlayPurchase(
	userId: string,
	productId: string,
	purchaseToken: string,
): Promise<{ valid: boolean; message: string; subscription?: object }> {
	const playApi = await getPlayDeveloperApi(googlePlayCredentials.value());

	// Get subscription details from Google Play
	const response = await playApi.purchases.subscriptionsv2.get({
		packageName: ANDROID_PACKAGE_NAME,
		token: purchaseToken,
	});

	const subscription = response.data;
	console.log(
		"Google Play subscription response:",
		JSON.stringify(subscription),
	);

	if (!subscription) {
		return { valid: false, message: "Subscription not found" };
	}

	// Check subscription state
	const subscriptionState = subscription.subscriptionState;

	// Valid states: SUBSCRIPTION_STATE_ACTIVE, SUBSCRIPTION_STATE_IN_GRACE_PERIOD
	const validStates = [
		"SUBSCRIPTION_STATE_ACTIVE",
		"SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
	];

	if (!subscriptionState || !validStates.includes(subscriptionState)) {
		console.log(`Subscription state is ${subscriptionState}, not valid`);
		return {
			valid: false,
			message: `Subscription is not active (state: ${subscriptionState})`,
		};
	}

	// Extract line item details (base plan info)
	const lineItems = subscription.lineItems || [];
	let basePlanId = "pro-monthly"; // Default
	let expiryTimeMillis: number | undefined;

	for (const lineItem of lineItems) {
		if (lineItem.productId === productId) {
			basePlanId = lineItem.offerDetails?.basePlanId || "pro-monthly";
			expiryTimeMillis = lineItem.expiryTime
				? new Date(lineItem.expiryTime).getTime()
				: undefined;
			break;
		}
	}

	// Check if this subscription is already linked to another account
	const existingSubscription = await db
		.collection("subscriptions")
		.where("purchaseToken", "==", purchaseToken)
		.limit(1)
		.get();

	if (!existingSubscription.empty) {
		const existingDoc = existingSubscription.docs[0];
		const existingData = existingDoc.data();

		if (existingData.userId !== userId) {
			console.warn(
				`Subscription already linked to user ${existingData.userId}, ` +
					`attempted by ${userId}`,
			);
			throw new HttpsError(
				"already-exists",
				"This subscription is already linked to another account. " +
					"Please contact support at support@betterkeep.app if you believe this is an error.",
			);
		}
	}

	// Calculate expiry date
	const expiresAt = expiryTimeMillis
		? Timestamp.fromMillis(expiryTimeMillis)
		: Timestamp.fromMillis(
				Date.now() +
					(SUBSCRIPTION_PLANS[basePlanId]?.periodDays || 30) *
						24 *
						60 *
						60 *
						1000,
			);

	// Store subscription in subscriptions collection (for global lookup)
	await db
		.collection("subscriptions")
		.doc(purchaseToken)
		.set(
			{
				userId,
				productId,
				purchaseToken,
				basePlanId,
				source: "play_store",
				subscriptionState,
				expiresAt,
				linkedToken: subscription.linkedPurchaseToken || null,
				orderId: subscription.latestOrderId || null,
				startTime: subscription.startTime
					? Timestamp.fromDate(new Date(subscription.startTime))
					: null,
				createdAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);

	// Update user's subscription status
	await db
		.collection("users")
		.doc(userId)
		.collection("subscription")
		.doc("status")
		.set({
			plan: "pro",
			billingPeriod: basePlanId === "pro-yearly" ? "yearly" : "monthly",
			expiresAt,
			willAutoRenew: subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
			purchaseToken,
			source: "play_store",
			basePlanId,
			verifiedAt: FieldValue.serverTimestamp(),
			updatedAt: FieldValue.serverTimestamp(),
		});

	// Set custom claims for server-side subscription enforcement
	await setSubscriptionClaims(userId, "pro", expiresAt.toDate());

	console.log(
		`Successfully verified and linked subscription for user ${userId}`,
	);

	return {
		valid: true,
		message: "Subscription verified and activated",
		subscription: {
			plan: "pro",
			billingPeriod: basePlanId === "pro-yearly" ? "yearly" : "monthly",
			expiresAt: expiresAt.toDate().toISOString(),
		},
	};
}

/**
 * Check if user already has an active subscription before making a new purchase.
 * Also attempts to recover/restore any existing subscription.
 */
export const checkExistingSubscription = onCall(
	{ secrets: [googlePlayCredentials] },
	async (request: CallableRequest<CheckSubscriptionRequest>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be signed in");
		}

		const userId = request.auth.uid;
		console.log(`Checking existing subscription for user ${userId}`);

		try {
			// Check user's current subscription status in Firestore
			const userSubRef = db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status");

			const userSubDoc = await userSubRef.get();

			if (userSubDoc.exists) {
				const subData = userSubDoc.data();
				if (!subData) return { hasSubscription: false };
				// Support both field names: expiresAt (Play Store) and expiryDate (Razorpay)
				const expiresAt =
					subData.expiresAt?.toDate() || subData.expiryDate?.toDate();

				// If subscription exists and not expired
				if (expiresAt && expiresAt > new Date()) {
					console.log(
						`User ${userId} has active subscription until ${expiresAt}`,
					);

					// Optionally verify with Google Play if we have a token
					if (subData.purchaseToken && subData.source === "play_store") {
						try {
							const playApi = await getPlayDeveloperApi(
								googlePlayCredentials.value(),
							);
							const response = await playApi.purchases.subscriptionsv2.get({
								packageName: ANDROID_PACKAGE_NAME,
								token: subData.purchaseToken,
							});

							const subscriptionState = response.data.subscriptionState;
							const isActive =
								subscriptionState === "SUBSCRIPTION_STATE_ACTIVE" ||
								subscriptionState === "SUBSCRIPTION_STATE_IN_GRACE_PERIOD";

							console.log(
								`Subscription state on Google for user ${userId}: ${subscriptionState}`,
							);

							if (!isActive) {
								// Subscription was cancelled or expired on Google's side
								// Check if it's a terminal state (cancelled, expired, revoked)
								const isTerminal =
									subscriptionState === "SUBSCRIPTION_STATE_CANCELED" ||
									subscriptionState === "SUBSCRIPTION_STATE_EXPIRED";

								if (isTerminal) {
									// Delete the subscription document - user is now on free plan
									console.log(
										`Subscription is terminal (${subscriptionState}), removing from user`,
									);
									await userSubRef.delete();
									return {
										hasSubscription: false,
										message: "Subscription has been cancelled or expired",
									};
								} else {
									// Just update the status (e.g., paused, pending)
									await userSubRef.update({
										willAutoRenew: false,
										subscriptionState,
										updatedAt: FieldValue.serverTimestamp(),
									});
								}
							}

							return {
								hasSubscription: isActive,
								subscription: {
									plan: subData.plan,
									billingPeriod: subData.billingPeriod,
									expiresAt: expiresAt.toISOString(),
									willAutoRenew:
										isActive &&
										subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
									source: subData.source,
								},
							};
						} catch (verifyError) {
							console.warn("Failed to verify with Google Play:", verifyError);
							// Fall back to local data
						}
					}

					return {
						hasSubscription: true,
						subscription: {
							plan: subData.plan,
							billingPeriod: subData.billingPeriod,
							expiresAt: expiresAt.toISOString(),
							willAutoRenew: subData.willAutoRenew ?? subData.autoRenew,
							source: subData.source,
						},
					};
				}
			}

			// Check if there's a subscription linked to this user in global subscriptions
			// Note: We query without orderBy to avoid needing a composite index.
			// For users with multiple subscriptions, we check all and use the one with the latest expiry.
			const linkedSubs = await db
				.collection("subscriptions")
				.where("userId", "==", userId)
				.get();

			if (!linkedSubs.empty) {
				// Find the subscription with the latest expiry date
				let latestSub: admin.firestore.QueryDocumentSnapshot | null = null;
				let latestExpiry: Date | null = null;

				for (const doc of linkedSubs.docs) {
					const subData = doc.data();
					const expiresAt = subData.expiresAt?.toDate();
					if (expiresAt && (!latestExpiry || expiresAt > latestExpiry)) {
						latestExpiry = expiresAt;
						latestSub = doc;
					}
				}

				if (latestSub && latestExpiry && latestExpiry > new Date()) {
					const subData = latestSub.data();
					// Found an active subscription - restore it
					console.log(`Restoring subscription for user ${userId}`);

					await userSubRef.set({
						plan: "pro",
						billingPeriod:
							subData.basePlanId === "pro-yearly" ? "yearly" : "monthly",
						expiresAt: subData.expiresAt,
						willAutoRenew:
							subData.subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
						purchaseToken: subData.purchaseToken,
						source: subData.source,
						basePlanId: subData.basePlanId,
						restoredAt: FieldValue.serverTimestamp(),
						updatedAt: FieldValue.serverTimestamp(),
					});

					return {
						hasSubscription: true,
						restored: true,
						subscription: {
							plan: "pro",
							billingPeriod:
								subData.basePlanId === "pro-yearly" ? "yearly" : "monthly",
							expiresAt: latestExpiry.toISOString(),
							willAutoRenew:
								subData.subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
							source: subData.source,
						},
					};
				}
			}

			// No active subscription found
			return {
				hasSubscription: false,
			};
		} catch (error) {
			console.error(`Error checking subscription for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to check subscription status");
		}
	},
);

/**
 * Restore subscription from a purchase token (for app crash recovery)
 */
export const restoreSubscription = onCall(
	{ secrets: [googlePlayCredentials] },
	async (request: CallableRequest<{ purchaseToken: string }>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be signed in");
		}

		const userId = request.auth.uid;
		const { purchaseToken } = request.data;

		if (!purchaseToken) {
			throw new HttpsError("invalid-argument", "Purchase token is required");
		}

		console.log(`Attempting to restore subscription for user ${userId}`);

		try {
			// Verify the subscription with Google Play
			const result = await verifyGooglePlayPurchase(
				userId,
				SUBSCRIPTION_PRODUCT_ID,
				purchaseToken,
			);

			if (result.valid) {
				return {
					success: true,
					message: "Subscription restored successfully",
					subscription: result.subscription,
				};
			} else {
				return {
					success: false,
					message: result.message,
				};
			}
		} catch (error) {
			console.error(`Error restoring subscription for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to restore subscription");
		}
	},
);

/**
 * Google Play Real-Time Developer Notifications (RTDN) webhook
 *
 * This handles subscription lifecycle events:
 * - Renewals
 * - Cancellations
 * - Expirations
 * - Grace period entries
 */
export const playStoreWebhook = onRequest(
	{ secrets: [googlePlayCredentials, emailPassword] },
	async (req, res) => {
		if (req.method !== "POST") {
			res.status(405).send("Method not allowed");
			return;
		}

		try {
			// Google sends a Pub/Sub message with base64-encoded data
			const message = req.body?.message;
			if (!message?.data) {
				console.warn("Invalid webhook payload - no message data");
				res.status(400).send("Invalid payload");
				return;
			}

			const dataBuffer = Buffer.from(message.data, "base64");
			const notification = JSON.parse(dataBuffer.toString());

			console.log(
				"Received Play Store notification:",
				JSON.stringify(notification),
			);

			const subscriptionNotification = notification.subscriptionNotification;
			if (!subscriptionNotification) {
				console.log("Not a subscription notification, ignoring");
				res.status(200).send("OK");
				return;
			}

			const { purchaseToken, notificationType } = subscriptionNotification;

			// Notification types:
			// 1 = SUBSCRIPTION_RECOVERED
			// 2 = SUBSCRIPTION_RENEWED
			// 3 = SUBSCRIPTION_CANCELED
			// 4 = SUBSCRIPTION_PURCHASED
			// 5 = SUBSCRIPTION_ON_HOLD
			// 6 = SUBSCRIPTION_IN_GRACE_PERIOD
			// 7 = SUBSCRIPTION_RESTARTED
			// 12 = SUBSCRIPTION_REVOKED
			// 13 = SUBSCRIPTION_EXPIRED

			console.log(
				`Processing notification type ${notificationType} for token ${purchaseToken}`,
			);

			// Find the user associated with this subscription first
			const subDoc = await db
				.collection("subscriptions")
				.doc(purchaseToken)
				.get();

			if (!subDoc.exists) {
				console.log(
					"Subscription not found in database, might be a new purchase",
				);
				res.status(200).send("OK");
				return;
			}

			const subData = subDoc.data();
			if (!subData) {
				console.log("Subscription data is empty");
				res.status(200).send("OK");
				return;
			}
			const userId = subData.userId;

			// Try to get subscription details from Google Play
			// If this fails (e.g., permissions issue), we can still handle
			// terminal states based on the notification type alone
			let subscriptionState: string | null = null;
			let expiresAt: Timestamp | null = null;

			try {
				const playApi = await getPlayDeveloperApi(
					googlePlayCredentials.value(),
				);
				const response = await playApi.purchases.subscriptionsv2.get({
					packageName: ANDROID_PACKAGE_NAME,
					token: purchaseToken,
				});

				const subscription = response.data;
				if (subscription) {
					subscriptionState = subscription.subscriptionState || null;

					// Extract expiry time from line items
					const lineItems = subscription.lineItems as
						| Array<{ expiryTime?: string }>
						| undefined;
					if (lineItems) {
						for (const lineItem of lineItems) {
							if (lineItem.expiryTime) {
								expiresAt = Timestamp.fromDate(new Date(lineItem.expiryTime));
								break;
							}
						}
					}
				}
			} catch (apiError) {
				console.warn(
					`Failed to get subscription details from Google Play API: ${apiError}`,
				);
				// Continue processing based on notification type alone
				// Map notification types to subscription states
				const notificationToState: Record<number, string> = {
					1: "SUBSCRIPTION_STATE_ACTIVE", // RECOVERED
					2: "SUBSCRIPTION_STATE_ACTIVE", // RENEWED
					3: "SUBSCRIPTION_STATE_CANCELED", // CANCELED
					5: "SUBSCRIPTION_STATE_ON_HOLD", // ON_HOLD
					6: "SUBSCRIPTION_STATE_IN_GRACE_PERIOD", // GRACE_PERIOD
					7: "SUBSCRIPTION_STATE_ACTIVE", // RESTARTED
					12: "SUBSCRIPTION_STATE_CANCELED", // REVOKED
					13: "SUBSCRIPTION_STATE_EXPIRED", // EXPIRED
				};
				subscriptionState = notificationToState[notificationType] || null;
			}

			// Update subscription record (use set with merge to handle missing fields)
			const subscriptionUpdate: Record<string, unknown> = {
				notificationType,
				lastNotificationAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			};
			if (subscriptionState) {
				subscriptionUpdate.subscriptionState = subscriptionState;
			}
			if (expiresAt) {
				subscriptionUpdate.expiresAt = expiresAt;
			}
			await db
				.collection("subscriptions")
				.doc(purchaseToken)
				.set(subscriptionUpdate, { merge: true });

			// Update user's subscription status
			const userSubRef = db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status");

			const isActive =
				subscriptionState === "SUBSCRIPTION_STATE_ACTIVE" ||
				subscriptionState === "SUBSCRIPTION_STATE_IN_GRACE_PERIOD";

			// Terminal states - subscription is fully ended
			const isTerminal =
				subscriptionState === "SUBSCRIPTION_STATE_EXPIRED" ||
				notificationType === 12 || // REVOKED
				notificationType === 13; // EXPIRED

			if (isActive) {
				await userSubRef.set(
					{
						expiresAt,
						willAutoRenew: subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
						subscriptionState,
						updatedAt: FieldValue.serverTimestamp(),
					},
					{ merge: true },
				);

				// Update custom claims for server-side enforcement
				if (expiresAt) {
					await setSubscriptionClaims(userId, "pro", expiresAt.toDate());
				}
			} else if (isTerminal) {
				// Terminal state - remove subscription to revert user to free plan
				console.log(`Terminal state for user ${userId}, removing subscription`);
				await userSubRef.delete();

				// Clear custom claims - user is now on free plan
				await setSubscriptionClaims(userId, "free", null);

				// Send notification email
				await sendSubscriptionNotificationEmail(
					userId,
					notificationType,
					expiresAt?.toDate() || null,
				);
			} else {
				// Non-terminal but not active (e.g., canceled but not yet expired, on hold)
				const shouldNotify = [3, 5, 6].includes(notificationType);

				if (shouldNotify) {
					await sendSubscriptionNotificationEmail(
						userId,
						notificationType,
						expiresAt?.toDate() || null,
					);
				}

				// Update status
				await userSubRef.set(
					{
						willAutoRenew: false,
						subscriptionState,
						updatedAt: FieldValue.serverTimestamp(),
					},
					{ merge: true },
				);
			}

			console.log(
				`Processed notification for user ${userId}: type=${notificationType}, state=${subscriptionState}`,
			);
			res.status(200).send("OK");
		} catch (error) {
			console.error("Error processing Play Store webhook:", error);
			res.status(500).send("Internal error");
		}
	},
);

/**
 * Send subscription welcome email to user after successful purchase
 */
async function sendSubscriptionWelcomeEmail(
	userId: string,
	subscription?: object,
): Promise<void> {
	try {
		const userRecord = await auth.getUser(userId);
		const email = userRecord.email;

		if (!email) {
			console.warn(`No email found for user ${userId}`);
			return;
		}

		const transporter = getEmailTransporter(emailPassword.value());
		const senderEmail = process.env.EMAIL_FROM;
		const senderName = process.env.EMAIL_NAME;

		const subData = subscription as
			| { plan?: string; billingPeriod?: string; expiresAt?: string }
			| undefined;
		const billingPeriod = subData?.billingPeriod || "monthly";
		const expiresAt = subData?.expiresAt
			? new Date(subData.expiresAt).toLocaleDateString()
			: "N/A";

		const htmlContent = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
        <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
          <div style="text-align: center; margin-bottom: 24px;">
            <img src="https://betterkeep.app/icons/logo.png" alt="Better Keep Notes" style="width: 64px; height: 64px;">
          </div>
          <h1 style="color: #333; font-size: 22px; margin-bottom: 20px;">Welcome to <strong>Better Keep Notes</strong> Pro</h1>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            Hi there,
          </p>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            Thank you for subscribing to <strong>Better Keep Notes Pro</strong>. Your payment has been processed and your account has been upgraded.
          </p>
          <div style="background: #f8f9fa; border-radius: 8px; padding: 16px; margin: 20px 0; border-left: 3px solid #6366f1;">
            <p style="color: #333; font-size: 15px; margin: 0 0 8px 0; font-weight: 600;">Subscription Details</p>
            <p style="color: #555; font-size: 15px; margin: 4px 0;">Plan: <strong>Pro ${
							billingPeriod === "yearly" ? "(Yearly)" : "(Monthly)"
						}</strong></p>
            <p style="color: #555; font-size: 15px; margin: 4px 0;">Next billing date: <strong>${expiresAt}</strong></p>
          </div>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 12px;">
            With your Pro subscription, you now have access to:
          </p>
          <ul style="color: #555; font-size: 15px; line-height: 1.8; padding-left: 20px; margin-bottom: 16px;">
            <li>Unlimited locked notes with biometric protection</li>
            <li>Real-time end-to-end encrypted cloud sync</li>
            <li>Priority support</li>
          </ul>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            If you have any questions about your subscription or need help getting started, contact us at <a href="mailto:support@betterkeep.app" style="color: #6366f1;">support@betterkeep.app</a>.
          </p>
          <p style="color: #555; font-size: 15px; line-height: 1.6;">
            Thanks again for your support.
          </p>
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 13px;">
            <strong>Better Keep Notes</strong> by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `;

		await sendEmail(transporter, {
			from: `"${senderName}" <${senderEmail}>`,
			to: email,
			subject: "Your Better Keep Notes Pro subscription is now active",
			html: htmlContent,
			text: `Hi there,\n\nThank you for subscribing to Better Keep Notes Pro. Your payment has been processed and your account has been upgraded.\n\nSubscription Details:\nPlan: Pro (${billingPeriod})\nNext billing date: ${expiresAt}\n\nWith your Pro subscription, you now have access to unlimited locked notes with biometric protection, real-time end-to-end encrypted cloud sync, and priority support.\n\nIf you have any questions, contact us at support@betterkeep.app.\n\nThanks again for your support.\n\nBetter Keep Notes by Foxbiz Software Pvt. Ltd.`,
		});

		console.log(`Sent welcome email to ${email}`);
	} catch (error) {
		console.error(`Failed to send welcome email to user ${userId}:`, error);
		// Don't throw - email failure shouldn't fail the purchase
	}
}

/**
 * Send subscription notification email to user
 */
async function sendSubscriptionNotificationEmail(
	userId: string,
	notificationType: number,
	expiresAt: Date | null,
): Promise<void> {
	try {
		const userRecord = await auth.getUser(userId);
		const email = userRecord.email;

		if (!email) {
			console.warn(`No email found for user ${userId}`);
			return;
		}

		const transporter = getEmailTransporter(emailPassword.value());
		const senderEmail = process.env.EMAIL_FROM;
		const senderName = process.env.EMAIL_NAME;

		let subject: string;
		let heading: string;
		let message: string;
		let actionText: string | null = null;
		let actionUrl: string | null = null;
		let extraContent: string = "";

		switch (notificationType) {
			case 3: // SUBSCRIPTION_CANCELED
				subject = "Your Better Keep Notes Pro subscription has been cancelled";
				heading = "Subscription Cancelled";
				message = expiresAt
					? `Your <strong>Better Keep Notes Pro</strong> subscription has been cancelled. You will continue to have access to Pro features until <strong>${expiresAt.toLocaleDateString()}</strong>.`
					: "Your <strong>Better Keep Notes Pro</strong> subscription has been cancelled.";
				extraContent = `
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            We would genuinely like to understand what led to this decision. Was there something missing, or something we could have done better?
          </p>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            If you have a moment, please share your feedback with us at <a href="mailto:feedback@betterkeep.app" style="color: #6366f1;">feedback@betterkeep.app</a>. It helps us improve <strong>Better Keep Notes</strong> for everyone.
          </p>
          <p style="color: #555; font-size: 15px; line-height: 1.6;">
            If you ever decide to come back, we'll be happy to have you.
          </p>
        `;
				actionText = "Resubscribe";
				actionUrl = "https://betterkeep.app/subscribe";
				break;

			case 5: // SUBSCRIPTION_ON_HOLD
				subject =
					"Action required: Your Better Keep Notes Pro subscription is on hold";
				heading = "Payment Issue";
				message =
					"We couldn't process your payment for <strong>Better Keep Notes Pro</strong>. Please update your payment method to continue your subscription.";
				actionText = "Update Payment";
				actionUrl = "https://play.google.com/store/account/subscriptions";
				break;

			case 6: // SUBSCRIPTION_IN_GRACE_PERIOD
				subject = "Payment issue with your Better Keep Notes Pro subscription";
				heading = "Grace Period Active";
				message =
					"We're having trouble processing your payment for <strong>Better Keep Notes Pro</strong>. You have a few days to update your payment method before losing access to Pro features.";
				actionText = "Update Payment";
				actionUrl = "https://play.google.com/store/account/subscriptions";
				break;

			case 12: // SUBSCRIPTION_REVOKED
				subject = "Your Better Keep Notes Pro subscription has been revoked";
				heading = "Subscription Revoked";
				message =
					"Your <strong>Better Keep Notes Pro</strong> subscription has been revoked. If you believe this is an error, please contact support.";
				actionText = "Contact Support";
				actionUrl = "mailto:support@betterkeep.app";
				break;

			case 13: // SUBSCRIPTION_EXPIRED
				subject = "Your Better Keep Notes Pro subscription has expired";
				heading = "Subscription Expired";
				message =
					"Your <strong>Better Keep Notes Pro</strong> subscription has expired. Resubscribe to regain access to unlimited locked notes, cloud sync, and more.";
				actionText = "Resubscribe";
				actionUrl = "https://betterkeep.app/subscribe";
				break;

			default:
				return; // Don't send email for other types
		}

		const htmlContent = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
        <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
          <div style="text-align: center; margin-bottom: 24px;">
            <img src="https://betterkeep.app/icons/logo.png" alt="Better Keep Notes" style="width: 64px; height: 64px;">
          </div>
          <h1 style="color: #333; font-size: 22px; margin-bottom: 20px;">${heading}</h1>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px;">
            ${message}
          </p>
          ${extraContent}
          ${
						actionText && actionUrl
							? `
          <div style="margin: 24px 0;">
            <a href="${actionUrl}" style="display: inline-block; background: #6366f1; color: white; padding: 12px 24px; border-radius: 8px; text-decoration: none; font-weight: 600; font-size: 15px;">
              ${actionText}
            </a>
          </div>
          `
							: ""
					}
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 13px;">
            If you have questions, contact us at <a href="mailto:support@betterkeep.app" style="color: #6366f1;">support@betterkeep.app</a>
          </p>
          <p style="color: #999; font-size: 13px; margin-top: 8px;">
            <strong>Better Keep Notes</strong> by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `;

		// For cancellation emails, add reply-to for feedback
		const replyTo =
			notificationType === 3 ? "feedback@betterkeep.app" : undefined;

		await sendEmail(transporter, {
			from: `"${senderName}" <${senderEmail}>`,
			replyTo: replyTo,
			to: email,
			subject,
			html: htmlContent,
			text: `${heading}\n\n${message}${
				extraContent
					? "\n\nWe'd love to hear your feedback! Reply to this email or write to feedback@betterkeep.app"
					: ""
			}${actionUrl ? `\n\n${actionText}: ${actionUrl}` : ""}`,
		});

		console.log(`Sent subscription notification email to ${email}`);
	} catch (error) {
		console.error(
			`Failed to send subscription email to user ${userId}:`,
			error,
		);
	}
}

/**
 * Send Razorpay subscription email (welcome, cancelled, resumed, renewal)
 */
async function sendRazorpaySubscriptionEmail(
	userId: string,
	type: "welcome" | "cancelled" | "resumed" | "renewed" | "expired",
	expiryDate?: Date | null,
): Promise<void> {
	try {
		const userRecord = await auth.getUser(userId);
		const email = userRecord.email;

		if (!email) {
			console.warn(`No email found for user ${userId}`);
			return;
		}

		const transporter = getEmailTransporter(emailPassword.value());
		const senderEmail = process.env.EMAIL_FROM;
		const senderName = process.env.EMAIL_NAME;

		let subject = "";
		let heading = "";
		let message = "";
		let ctaText = "";
		let ctaUrl = "";

		const expiryStr = expiryDate ? expiryDate.toLocaleDateString() : "N/A";

		switch (type) {
			case "welcome":
				subject = "Welcome to Better Keep Notes Pro! 🎉";
				heading = "Welcome to Better Keep Notes Pro";
				message = `Thank you for subscribing! Your account has been upgraded and you now have access to all Pro features including unlimited locked notes, real-time encrypted sync, and priority support.\n\nYour subscription will renew on ${expiryStr}.`;
				ctaText = "Open Better Keep Notes";
				ctaUrl = "https://betterkeep.app";
				break;
			case "cancelled":
				subject = "Your Better Keep Notes subscription has been cancelled";
				heading = "Subscription Cancelled";
				message = `Your subscription has been cancelled. You'll continue to have Pro access until ${expiryStr}, after which you'll be switched to the free plan.\n\nYou can resume your subscription anytime before it expires to keep your Pro benefits.`;
				ctaText = "Resume Subscription";
				ctaUrl = "https://betterkeep.app";
				break;
			case "resumed":
				subject = "Your Better Keep Notes subscription has been resumed";
				heading = "Subscription Resumed";
				message = `Great news! Your subscription has been resumed and will renew automatically on ${expiryStr}. You'll continue to enjoy all Pro features.`;
				ctaText = "Open Better Keep Notes";
				ctaUrl = "https://betterkeep.app";
				break;
			case "renewed":
				subject = "Your Better Keep Notes subscription has been renewed";
				heading = "Subscription Renewed";
				message = `Your Pro subscription has been renewed successfully. Your next billing date is ${expiryStr}. Thank you for your continued support!`;
				ctaText = "Open Better Keep Notes";
				ctaUrl = "https://betterkeep.app";
				break;
			case "expired":
				subject = "Your Better Keep Notes Pro subscription has expired";
				heading = "Subscription Expired";
				message = `Your Pro subscription has expired and your account has been switched to the free plan. You can resubscribe anytime to regain access to Pro features.`;
				ctaText = "Resubscribe to Pro";
				ctaUrl = "https://betterkeep.app";
				break;
		}

		const htmlContent = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
        <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
          <div style="text-align: center; margin-bottom: 24px;">
            <img src="https://betterkeep.app/icons/logo.png" alt="Better Keep Notes" style="width: 64px; height: 64px;">
          </div>
          <h1 style="color: #333; font-size: 22px; margin-bottom: 20px;">${heading}</h1>
          <p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px; white-space: pre-line;">
            ${message}
          </p>
          <div style="text-align: center; margin: 24px 0;">
            <a href="${ctaUrl}" style="background: #6366f1; color: white; padding: 12px 24px; border-radius: 8px; text-decoration: none; font-weight: 600; display: inline-block;">${ctaText}</a>
          </div>
          <p style="color: #555; font-size: 15px; line-height: 1.6;">
            If you have any questions, contact us at <a href="mailto:support@betterkeep.app" style="color: #6366f1;">support@betterkeep.app</a>.
          </p>
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 13px;">
            <strong>Better Keep Notes</strong> by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `;

		await sendEmail(transporter, {
			from: `"${senderName}" <${senderEmail}>`,
			to: email,
			subject: subject,
			html: htmlContent,
			text: `${heading}\n\n${message}\n\n${ctaText}: ${ctaUrl}\n\nBetter Keep Notes by Foxbiz Software Pvt. Ltd.`,
		});

		console.log(`Sent Razorpay ${type} email to ${email}`);
	} catch (error) {
		console.error(
			`Failed to send Razorpay subscription email to user ${userId}:`,
			error,
		);
	}
}

/**
 * Scheduled function to check for expired subscriptions and notify users
 * Runs daily at 9:00 AM UTC
 */
export const checkExpiredSubscriptions = onSchedule(
	{
		schedule: "0 9 * * *",
		secrets: [emailPassword],
	},
	async () => {
		console.log("Running expired subscription check...");

		try {
			const now = Timestamp.now();
			const oneDayFromNow = Timestamp.fromMillis(
				Date.now() + 24 * 60 * 60 * 1000,
			);

			// Find subscriptions expiring within 24 hours that haven't been notified
			const expiringSubsSnapshot = await db
				.collection("subscriptions")
				.where("expiresAt", ">", now)
				.where("expiresAt", "<", oneDayFromNow)
				.where("expiryNotificationSent", "!=", true)
				.get();

			console.log(
				`Found ${expiringSubsSnapshot.size} subscriptions expiring soon`,
			);

			for (const doc of expiringSubsSnapshot.docs) {
				const subData = doc.data();
				const userId = subData.userId;
				const expiresAt = subData.expiresAt?.toDate();

				if (!userId || !expiresAt) continue;

				try {
					// Get user email
					const userRecord = await auth.getUser(userId);
					const email = userRecord.email;

					if (email) {
						const transporter = getEmailTransporter(emailPassword.value());
						const senderEmail = process.env.EMAIL_FROM;
						const senderName = process.env.EMAIL_NAME;

						await sendEmail(transporter, {
							from: `"${senderName}" <${senderEmail}>`,
							to: email,
							subject: "Your Better Keep Pro subscription is expiring soon",
							html: `
                <!DOCTYPE html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta name="viewport" content="width=device-width, initial-scale=1.0">
                </head>
                <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
                  <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
                    <h1 style="color: #333; font-size: 24px; margin-bottom: 16px;">Subscription Expiring Soon</h1>
                    <p style="color: #666; font-size: 16px; line-height: 1.5;">
                      Your Better Keep Pro subscription will expire on <strong>${expiresAt.toLocaleDateString()}</strong>.
                    </p>
                    <p style="color: #666; font-size: 16px; line-height: 1.5;">
                      To continue enjoying unlimited locked notes and cloud sync, make sure your subscription auto-renews or resubscribe.
                    </p>
                    <div style="margin: 24px 0;">
                      <a href="https://play.google.com/store/account/subscriptions" style="display: inline-block; background: #6366f1; color: white; padding: 12px 24px; border-radius: 8px; text-decoration: none; font-weight: 600;">
                        Manage Subscription
                      </a>
                    </div>
                    <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
                    <p style="color: #999; font-size: 12px;">
                      If you have questions, contact us at support@betterkeep.app
                    </p>
                    <p style="color: #bbb; font-size: 11px; margin-top: 8px;">
                      Better Keep by Foxbiz Software Pvt. Ltd.
                    </p>
                  </div>
                </body>
                </html>
              `,
							text: `Your Better Keep Pro subscription will expire on ${expiresAt.toLocaleDateString()}. To continue enjoying Pro features, make sure your subscription auto-renews.`,
						});

						console.log(`Sent expiry warning to ${email}`);
					}

					// Mark as notified
					await doc.ref.update({
						expiryNotificationSent: true,
						expiryNotificationSentAt: FieldValue.serverTimestamp(),
					});
				} catch (userError) {
					console.error(
						`Failed to process expiring sub for user ${userId}:`,
						userError,
					);
				}
			}

			// Also update expired subscriptions (disable features)
			const expiredSubsSnapshot = await db
				.collection("subscriptions")
				.where("expiresAt", "<", now)
				.where("subscriptionState", "in", [
					"SUBSCRIPTION_STATE_ACTIVE",
					"SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
				])
				.get();

			console.log(
				`Found ${expiredSubsSnapshot.size} expired subscriptions to update`,
			);

			for (const doc of expiredSubsSnapshot.docs) {
				const subData = doc.data();
				const userId = subData.userId;

				try {
					// Update subscription state
					await doc.ref.update({
						subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
						updatedAt: FieldValue.serverTimestamp(),
					});

					// Update user subscription status - delete it to revert to free plan
					await db
						.collection("users")
						.doc(userId)
						.collection("subscription")
						.doc("status")
						.delete();

					console.log(`Removed expired subscription for user ${userId}`);
				} catch (updateError) {
					console.error(
						`Failed to update expired sub for user ${userId}:`,
						updateError,
					);
				}
			}

			console.log("Expired subscription check completed");
		} catch (error) {
			console.error("Error in expired subscription check:", error);
		}
	},
);

// ============================================================================
// RAZORPAY PAYMENT INTEGRATION
// ============================================================================

/**
 * Helper function to make Razorpay API requests
 */
async function razorpayRequest(
	keyId: string,
	keySecret: string,
	method: string,
	endpoint: string,
	body?: Record<string, unknown>,
): Promise<unknown> {
	// Debug: log key lengths to verify they're populated (not the actual keys)
	console.log(
		`Razorpay request: ${method} ${endpoint}, keyId length: ${keyId?.length}, keySecret length: ${keySecret?.length}`,
	);

	if (!keyId || !keySecret) {
		throw new Error("Razorpay credentials not configured");
	}

	const auth = Buffer.from(`${keyId}:${keySecret}`).toString("base64");

	const response = await fetch(`https://api.razorpay.com/v1${endpoint}`, {
		method,
		headers: {
			Authorization: `Basic ${auth}`,
			"Content-Type": "application/json",
		},
		body: body ? JSON.stringify(body) : undefined,
	});

	if (!response.ok) {
		const errorText = await response.text();
		console.error(`Razorpay API error: ${response.status} - ${errorText}`);
		throw new Error(`Razorpay API error: ${response.status}`);
	}

	return response.json();
}

/**
 * Get or create a Razorpay plan
 * Creates plan if it doesn't exist, returns existing plan ID otherwise
 */
async function getOrCreateRazorpayPlan(
	keyId: string,
	keySecret: string,
	planType: "monthly" | "yearly",
): Promise<string> {
	const planConfig = RAZORPAY_PLANS[planType];
	// v2: Updated pricing - ₹230/month, ₹1625/year (Dec 2024)
	const planName = `better_keep_pro_${planType}_v2`;

	try {
		// First, try to find existing plan by listing plans
		const plansResponse = (await razorpayRequest(
			keyId,
			keySecret,
			"GET",
			"/plans?count=100",
		)) as { items: Array<{ id: string; item: { name: string } }> };

		const existingPlan = plansResponse.items?.find(
			(p) => p.item?.name === planName,
		);

		if (existingPlan) {
			console.log(`Found existing Razorpay plan: ${existingPlan.id}`);
			return existingPlan.id;
		}

		// Create new plan
		console.log(`Creating new Razorpay plan: ${planName}`);
		const newPlan = (await razorpayRequest(keyId, keySecret, "POST", "/plans", {
			period: planType === "yearly" ? "yearly" : "monthly",
			interval: 1,
			item: {
				name: planName,
				amount: planConfig.amount,
				currency: planConfig.currency,
				description: planConfig.name,
			},
		})) as { id: string };

		console.log(`Created Razorpay plan: ${newPlan.id}`);
		return newPlan.id;
	} catch (error) {
		console.error(`Error getting/creating plan ${planType}:`, error);
		throw error;
	}
}

/**
 * Create a Razorpay subscription for the user
 * Called from web/desktop clients
 */
export const createRazorpaySubscription = onCall(
	{
		secrets: [razorpayKeyId, razorpayKeySecret],
		cors: true,
	},
	async (request: CallableRequest<{ yearly: boolean }>) => {
		// Verify user is authenticated
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;
		const { yearly } = request.data;
		const planType = yearly ? "yearly" : "monthly";
		const plan = RAZORPAY_PLANS[planType];

		console.log(
			`Creating Razorpay subscription for user ${userId}, yearly: ${yearly}`,
		);

		try {
			// Check for existing active subscription
			const existingSubDoc = await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.get();

			if (existingSubDoc.exists) {
				const existingSub = existingSubDoc.data();
				if (
					existingSub &&
					existingSub.plan !== "free" &&
					existingSub.subscriptionState === "SUBSCRIPTION_STATE_ACTIVE"
				) {
					// Check if not expired
					const expiryDate = existingSub.expiryDate?.toDate?.();
					if (expiryDate && expiryDate > new Date()) {
						console.log(
							`User ${userId} already has an active subscription: ${existingSub.plan}`,
						);
						throw new HttpsError(
							"already-exists",
							"You already have an active subscription. Please cancel your current subscription first if you want to change plans.",
						);
					}
				}
			}

			const keyId = razorpayKeyId.value().trim();
			const keySecret = razorpayKeySecret.value().trim();

			// Get or create the plan
			const planId = await getOrCreateRazorpayPlan(keyId, keySecret, planType);

			// Create a subscription
			const subscription = await razorpayRequest(
				keyId,
				keySecret,
				"POST",
				"/subscriptions",
				{
					plan_id: planId,
					total_count: 120, // Max billing cycles
					quantity: 1,
					customer_notify: 1,
					notes: {
						userId: userId,
						plan: planType,
					},
				},
			);

			const subData = subscription as {
				id: string;
				short_url: string;
				status: string;
			};

			// Store pending payment in Firebase
			await db.collection("payments").doc(subData.id).set({
				userId,
				type: "subscription",
				plan: planType,
				amount: plan.amount,
				currency: plan.currency,
				razorpaySubscriptionId: subData.id,
				razorpayPlanId: planId,
				status: "created",
				createdAt: FieldValue.serverTimestamp(),
			});

			console.log(
				`Created Razorpay subscription ${subData.id} for user ${userId}`,
			);

			return {
				subscriptionId: subData.id,
				keyId: keyId,
				amount: plan.amount,
				currency: plan.currency,
				name: plan.name,
			};
		} catch (error) {
			console.error("Error creating Razorpay subscription:", error);
			// Re-throw HttpsError as-is, only wrap other errors
			if (error instanceof HttpsError) {
				throw error;
			}
			throw new HttpsError("internal", "Failed to create subscription");
		}
	},
);

/**
 * Verify Razorpay subscription payment
 * Called after successful payment on client
 */
export const verifyRazorpaySubscription = onCall(
	{
		secrets: [razorpayKeySecret, emailPassword],
	},
	async (
		request: CallableRequest<{
			subscriptionId: string;
			paymentId: string;
			signature: string;
		}>,
	) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;
		const { subscriptionId, paymentId, signature } = request.data;

		console.log(
			`Verifying Razorpay subscription ${subscriptionId} for user ${userId}`,
		);

		try {
			const keySecret = razorpayKeySecret.value().trim();

			// Verify signature
			const expectedSignature = crypto
				.createHmac("sha256", keySecret)
				.update(`${paymentId}|${subscriptionId}`)
				.digest("hex");

			if (signature !== expectedSignature) {
				console.error("Invalid Razorpay signature");
				throw new HttpsError("invalid-argument", "Invalid payment signature");
			}

			// Get payment details from Firebase
			const paymentDoc = await db
				.collection("payments")
				.doc(subscriptionId)
				.get();

			if (!paymentDoc.exists) {
				throw new HttpsError("not-found", "Payment not found");
			}

			const paymentData = paymentDoc.data();
			if (!paymentData) {
				throw new HttpsError("not-found", "Payment data not found");
			}

			if (paymentData.userId !== userId) {
				throw new HttpsError(
					"permission-denied",
					"Payment does not belong to user",
				);
			}

			// Calculate expiry based on plan
			const now = new Date();
			const expiryDate = new Date(now);
			if (paymentData.plan === "yearly") {
				expiryDate.setFullYear(expiryDate.getFullYear() + 1);
			} else {
				expiryDate.setMonth(expiryDate.getMonth() + 1);
			}

			// Update payment status
			await paymentDoc.ref.update({
				status: "verified",
				razorpayPaymentId: paymentId,
				razorpaySignature: signature,
				verifiedAt: FieldValue.serverTimestamp(),
			});

			// Activate subscription for user
			await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.set({
					plan: "pro",
					source: "razorpay",
					razorpaySubscriptionId: subscriptionId,
					razorpayPaymentId: paymentId,
					billingPeriod: paymentData.plan,
					startDate: Timestamp.now(),
					expiryDate: Timestamp.fromDate(expiryDate),
					autoRenew: true,
					subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
					updatedAt: FieldValue.serverTimestamp(),
				});

			// Set custom claims for server-side enforcement
			await setSubscriptionClaims(userId, "pro", expiryDate);

			console.log(
				`Activated subscription for user ${userId}, expires ${expiryDate.toISOString()}`,
			);

			// Send welcome email
			await sendRazorpaySubscriptionEmail(userId, "welcome", expiryDate);

			return { success: true, expiryDate: expiryDate.toISOString() };
		} catch (error) {
			console.error("Error verifying Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to verify subscription");
		}
	},
);

/**
 * Cancel a Razorpay subscription
 */
export const cancelRazorpaySubscription = onCall(
	{
		secrets: [razorpayKeyId, razorpayKeySecret, emailPassword],
	},
	async (request: CallableRequest<Record<string, never>>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;

		console.log(`Cancelling Razorpay subscription for user ${userId}`);

		try {
			const keyId = razorpayKeyId.value().trim();
			const keySecret = razorpayKeySecret.value().trim();

			// Get user's subscription
			const subDoc = await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.get();

			if (!subDoc.exists) {
				throw new HttpsError("not-found", "No active subscription found");
			}

			const subData = subDoc.data();

			if (subData?.source !== "razorpay" || !subData.razorpaySubscriptionId) {
				throw new HttpsError(
					"failed-precondition",
					"Subscription was not purchased via Razorpay",
				);
			}

			// Get actual subscription status from Razorpay first
			const razorpaySub = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/subscriptions/${subData.razorpaySubscriptionId}`,
			)) as { status: string };

			console.log(`Razorpay subscription status: ${razorpaySub.status}`);

			// Determine cancel mode based on subscription state
			// For subscriptions not yet in active billing cycle, cancel immediately
			// For active subscriptions, cancel at end of cycle
			const cancelImmediately =
				razorpaySub.status === "created" ||
				razorpaySub.status === "authenticated" ||
				razorpaySub.status === "pending";

			// Cancel subscription in Razorpay
			await razorpayRequest(
				keyId,
				keySecret,
				"POST",
				`/subscriptions/${subData.razorpaySubscriptionId}/cancel`,
				cancelImmediately
					? { cancel_at_cycle_end: 0 }
					: { cancel_at_cycle_end: 1 },
			);

			// Update subscription status
			if (cancelImmediately) {
				// Subscription cancelled immediately - delete it
				await subDoc.ref.delete();
				console.log(
					`Immediately cancelled and removed subscription for user ${userId}`,
				);
			} else {
				// Subscription cancelled at cycle end - mark as cancelled
				await subDoc.ref.update({
					autoRenew: false,
					subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
					cancelledAt: FieldValue.serverTimestamp(),
					updatedAt: FieldValue.serverTimestamp(),
				});
				console.log(`Cancelled subscription for user ${userId} at cycle end`);
			}

			// Send cancellation email
			await sendRazorpaySubscriptionEmail(
				userId,
				"cancelled",
				cancelImmediately ? null : subData.expiryDate?.toDate(),
			);

			return { success: true, immediate: cancelImmediately };
		} catch (error) {
			console.error("Error cancelling Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to cancel subscription");
		}
	},
);

/**
 * Resume a cancelled Razorpay subscription
 */
export const resumeRazorpaySubscription = onCall(
	{
		secrets: [razorpayKeyId, razorpayKeySecret, emailPassword],
	},
	async (request: CallableRequest<Record<string, never>>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;

		console.log(`Resuming Razorpay subscription for user ${userId}`);

		try {
			const keyId = razorpayKeyId.value().trim();
			const keySecret = razorpayKeySecret.value().trim();

			// Get user's subscription
			const subDoc = await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.get();

			if (!subDoc.exists) {
				throw new HttpsError("not-found", "No subscription found");
			}

			const subData = subDoc.data();

			if (subData?.source !== "razorpay" || !subData.razorpaySubscriptionId) {
				throw new HttpsError(
					"failed-precondition",
					"Subscription was not purchased via Razorpay",
				);
			}

			// Check if subscription is actually cancelled in our records
			if (subData.subscriptionState !== "SUBSCRIPTION_STATE_CANCELED") {
				throw new HttpsError(
					"failed-precondition",
					"Subscription is not in cancelled state",
				);
			}

			// Get actual subscription status from Razorpay
			const razorpaySub = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/subscriptions/${subData.razorpaySubscriptionId}`,
			)) as { status: string };

			console.log(`Razorpay subscription status: ${razorpaySub.status}`);

			// Handle based on actual Razorpay status
			if (razorpaySub.status === "active") {
				// Subscription is still active in Razorpay (cancel_at_cycle_end was set)
				// Unfortunately, Razorpay doesn't support undoing cancel_at_cycle_end
				// The user needs to create a new subscription when this one expires
				throw new HttpsError(
					"failed-precondition",
					"Cannot resume a subscription that was cancelled at cycle end. " +
						"Your current subscription will remain active until it expires. " +
						"You can subscribe again after it expires.",
				);
			} else if (
				razorpaySub.status === "halted" ||
				razorpaySub.status === "paused"
			) {
				// Subscription can be resumed
				await razorpayRequest(
					keyId,
					keySecret,
					"POST",
					`/subscriptions/${subData.razorpaySubscriptionId}/resume`,
					{ resume_at: "now" },
				);

				// Update subscription status
				await subDoc.ref.update({
					autoRenew: true,
					subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
					cancelledAt: admin.firestore.FieldValue.delete(),
					updatedAt: FieldValue.serverTimestamp(),
				});

				console.log(`Resumed subscription for user ${userId}`);

				// Send resume email
				await sendRazorpaySubscriptionEmail(
					userId,
					"resumed",
					subData.expiryDate?.toDate(),
				);

				return { success: true };
			} else if (razorpaySub.status === "cancelled") {
				// Subscription is fully cancelled in Razorpay - can't resume
				throw new HttpsError(
					"failed-precondition",
					"This subscription has been fully cancelled and cannot be resumed. " +
						"Please create a new subscription.",
				);
			} else {
				throw new HttpsError(
					"failed-precondition",
					`Subscription is in '${razorpaySub.status}' state and cannot be resumed.`,
				);
			}
		} catch (error) {
			console.error("Error resuming Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to resume subscription");
		}
	},
);

/**
 * DEBUG ONLY: Delete subscription for testing
 * This immediately removes the subscription from Firestore
 * Only available in emulator environment
 */
export const debugDeleteSubscription = onCall(
	async (request: CallableRequest<Record<string, never>>) => {
		// Only allow in emulator
		if (!process.env.FUNCTIONS_EMULATOR) {
			throw new HttpsError(
				"failed-precondition",
				"This function is only available in development",
			);
		}

		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;

		console.log(`DEBUG: Deleting subscription for user ${userId}`);

		try {
			// Delete the subscription document
			await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.delete();

			console.log(`DEBUG: Deleted subscription for user ${userId}`);

			return { success: true, message: "Subscription deleted for testing" };
		} catch (error) {
			console.error("Error deleting subscription:", error);
			throw new HttpsError("internal", "Failed to delete subscription");
		}
	},
);

/**
 * Razorpay webhook handler
 * Handles subscription lifecycle events
 */
export const razorpayWebhook = onRequest(
	{
		secrets: [razorpayKeySecret],
	},
	async (req, res) => {
		if (req.method !== "POST") {
			res.status(405).send("Method Not Allowed");
			return;
		}

		const signature = req.headers["x-razorpay-signature"] as string;
		const body = JSON.stringify(req.body);

		try {
			const keySecret = razorpayKeySecret.value().trim();

			// Verify webhook signature
			const expectedSignature = crypto
				.createHmac("sha256", keySecret)
				.update(body)
				.digest("hex");

			if (signature !== expectedSignature) {
				console.error("Invalid Razorpay webhook signature");
				res.status(400).send("Invalid signature");
				return;
			}

			const event = req.body;
			console.log(`Razorpay webhook: ${event.event}`);

			switch (event.event) {
				case "subscription.charged": {
					// Subscription renewal successful
					const subscription = event.payload.subscription.entity;
					const payment = event.payload.payment.entity;

					// Find user by subscription ID
					const paymentsQuery = await db
						.collection("payments")
						.where("razorpaySubscriptionId", "==", subscription.id)
						.limit(1)
						.get();

					if (!paymentsQuery.empty) {
						const paymentDoc = paymentsQuery.docs[0];
						const userId = paymentDoc.data().userId;

						// Calculate new expiry
						const now = new Date();
						const expiryDate = new Date(now);
						const plan = paymentDoc.data().plan;
						if (plan === "yearly") {
							expiryDate.setFullYear(expiryDate.getFullYear() + 1);
						} else {
							expiryDate.setMonth(expiryDate.getMonth() + 1);
						}

						// Update subscription
						await db
							.collection("users")
							.doc(userId)
							.collection("subscription")
							.doc("status")
							.update({
								razorpayPaymentId: payment.id,
								expiryDate: Timestamp.fromDate(expiryDate),
								subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
								updatedAt: FieldValue.serverTimestamp(),
							});

						// Update custom claims for server-side enforcement
						await setSubscriptionClaims(userId, "pro", expiryDate);

						// Record the payment
						await db.collection("payments").add({
							userId,
							type: "renewal",
							razorpaySubscriptionId: subscription.id,
							razorpayPaymentId: payment.id,
							amount: payment.amount,
							currency: payment.currency,
							status: "verified",
							createdAt: FieldValue.serverTimestamp(),
						});

						console.log(`Renewed subscription for user ${userId}`);
					}
					break;
				}

				case "subscription.cancelled": {
					const subscription = event.payload.subscription.entity;

					const paymentsQuery = await db
						.collection("payments")
						.where("razorpaySubscriptionId", "==", subscription.id)
						.limit(1)
						.get();

					if (!paymentsQuery.empty) {
						const userId = paymentsQuery.docs[0].data().userId;

						await db
							.collection("users")
							.doc(userId)
							.collection("subscription")
							.doc("status")
							.update({
								autoRenew: false,
								subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
								updatedAt: FieldValue.serverTimestamp(),
							});

						console.log(`Subscription cancelled for user ${userId}`);
					}
					break;
				}

				case "subscription.halted":
				case "subscription.expired": {
					const subscription = event.payload.subscription.entity;

					const paymentsQuery = await db
						.collection("payments")
						.where("razorpaySubscriptionId", "==", subscription.id)
						.limit(1)
						.get();

					if (!paymentsQuery.empty) {
						const userId = paymentsQuery.docs[0].data().userId;

						// Remove subscription
						await db
							.collection("users")
							.doc(userId)
							.collection("subscription")
							.doc("status")
							.delete();

						// Clear custom claims - user is now on free plan
						await setSubscriptionClaims(userId, "free", null);

						console.log(`Subscription expired/halted for user ${userId}`);
					}
					break;
				}

				case "payment.failed": {
					const payment = event.payload.payment.entity;
					console.log(`Payment failed: ${payment.id}`);
					// You could notify the user here
					break;
				}

				default:
					console.log(`Unhandled Razorpay event: ${event.event}`);
			}

			res.status(200).send("OK");
		} catch (error) {
			console.error("Error processing Razorpay webhook:", error);
			res.status(500).send("Internal Server Error");
		}
	},
);

/**
 * Cleanup failed/abandoned Razorpay payments
 * Runs daily at 3 AM
 */
export const cleanupFailedRazorpayPayments = onSchedule(
	{
		schedule: "0 3 * * *", // Daily at 3 AM
		timeZone: "Asia/Kolkata",
	},
	async () => {
		console.log("Starting cleanup of failed Razorpay payments");

		try {
			// Find payments older than 24 hours that are still in 'created' status
			const cutoff = new Date();
			cutoff.setHours(cutoff.getHours() - 24);

			const failedPayments = await db
				.collection("payments")
				.where("status", "==", "created")
				.where("createdAt", "<", Timestamp.fromDate(cutoff))
				.get();

			console.log(
				`Found ${failedPayments.size} failed/abandoned payments to cleanup`,
			);

			const batch = db.batch();
			for (const doc of failedPayments.docs) {
				batch.delete(doc.ref);
			}

			await batch.commit();
			console.log("Cleanup completed");
		} catch (error) {
			console.error("Error cleaning up failed payments:", error);
		}
	},
);

/**
 * Grant 7-day Pro trial to new users on their first successful sign-in.
 * Using beforeUserSignedIn instead of beforeUserCreated to ensure the trial
 * is only granted after a successful sign-in, preventing orphaned trials
 * when sign-in fails after user creation.
 *
 * Trial is only granted once per email (tracked via Firestore trialUsage collection).
 * Also ensures user document exists and sends welcome email with trial info.
 */
export const grantTrialOnFirstSignIn = beforeUserSignedIn(
	{
		secrets: [emailPassword],
		// Note: minInstances removed to save cost. Cold starts may occasionally
		// cause timeouts for Google sign-in, but OAuth providers (Facebook, GitHub, 
		// Twitter) now grant trials directly in the OAuth callback.
		// If you experience cold start issues with Google sign-in, add: minInstances: 1
	},
	async (event) => {
		// Check if trial is enabled via environment variable
		if (!TRIAL_ENABLED) {
			return {};
		}

		const user = event.data;
		const userId = user.uid;
		// Handle null/undefined email gracefully (Twitter users may not have email)
		const email = user.email?.trim()?.toLowerCase() || null;
		const emailKey = email || `no-email-${userId}`;

		console.log(`User signing in: ${userId} (${email || "no email"})`);

		try {
			// Fast path: Check subscription and trial usage in parallel
			const userRef = db.collection("users").doc(userId);
			const subscriptionRef = userRef.collection("subscription").doc("status");
			const trialRef = db.collection("trialUsage").doc(emailKey);

			const [existingSubscription, trialDoc] = await Promise.all([
				subscriptionRef.get(),
				trialRef.get(),
			]);

			// Already has subscription - return immediately (most common case for returning users)
			if (existingSubscription.exists) {
				console.log(`User ${userId} already has subscription`);
				return {};
			}

			// Email already used trial - return immediately
			if (trialDoc.exists) {
				console.log(`Email ${email} already used trial`);
				return {};
			}

			// New user needs trial - calculate expiry
			const trialExpiresAt = new Date();
			if (DEBUG_TRIAL_MINUTES !== null) {
				trialExpiresAt.setMinutes(
					trialExpiresAt.getMinutes() + DEBUG_TRIAL_MINUTES,
				);
			} else {
				trialExpiresAt.setDate(trialExpiresAt.getDate() + TRIAL_DAYS);
			}

			console.log(
				`Granting trial to ${userId}, expires ${trialExpiresAt.toISOString()}`,
			);

			// Write operations in parallel for speed
			await Promise.all([
				// Mark trial as used (by email if available, else by userId)
				trialRef.set({
					userId: userId,
					email: email || "none",
					trialStartedAt: Timestamp.now(),
					trialExpiresAt: Timestamp.fromDate(trialExpiresAt),
					createdAt: Timestamp.now(),
				}),
				// Create/update user document
				userRef.set(
					{
						email: email,
						displayName: user.displayName || null,
						photoURL: user.photoURL || null,
						createdAt: Timestamp.now(),
						lastSeen: Timestamp.now(),
					},
					{ merge: true },
				),
				// Create trial subscription
				subscriptionRef.set({
					plan: "pro",
					source: "trial",
					expiryDate: Timestamp.fromDate(trialExpiresAt),
					billingPeriod: "trial",
					willAutoRenew: false,
					status: "trial",
					trialStartedAt: Timestamp.now(),
					updatedAt: Timestamp.now(),
				}),
			]);

			console.log(`Trial granted to ${userId}`);

			// Send email in background (don't await - don't block sign-in)
			if (email) {
				sendTrialWelcomeEmail(
					email,
					user.displayName || "there",
					trialExpiresAt,
				).catch((e) => console.error(`Email send failed: ${e}`));
			}

			return {
				customClaims: {
					plan: "pro",
					planExpiresAt: trialExpiresAt.getTime(),
				},
			};
		} catch (error) {
			console.error(`Error granting trial: ${error}`);
			// Don't block sign-in on error
			return {};
		}
	},
);

/**
 * Send trial welcome email to new user
 */
async function sendTrialWelcomeEmail(
	email: string,
	displayName: string,
	expiresAt: Date,
): Promise<void> {
	const transporter = getEmailTransporter(emailPassword.value());
	const senderEmail = process.env.EMAIL_FROM;
	const senderName = process.env.EMAIL_NAME;

	const expiryDateStr = expiresAt.toLocaleDateString("en-US", {
		weekday: "long",
		year: "numeric",
		month: "long",
		day: "numeric",
	});

	const mailOptions = {
		from: `"${senderName}" <${senderEmail}>`,
		to: email,
		subject: "Welcome to Better Keep Pro - Your Free Trial Has Started! 🎉",
		html: `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
        <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
          <h1 style="color: #6750A4; font-size: 24px; margin-bottom: 16px;">Welcome to Better Keep Pro! 🎉</h1>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            Hi ${displayName},
          </p>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            Thank you for signing up! We've activated your <strong>free Pro trial</strong> so you can experience all the premium features.
          </p>
          <div style="background: linear-gradient(135deg, #6750A4 0%, #9C27B0 100%); border-radius: 8px; padding: 20px; text-align: center; margin: 24px 0; color: white;">
            <p style="margin: 0; font-size: 14px; opacity: 0.9;">Your trial expires on</p>
            <p style="margin: 8px 0 0 0; font-size: 20px; font-weight: bold;">${expiryDateStr}</p>
          </div>
          <p style="color: #333; font-size: 16px; line-height: 1.5; font-weight: 600;">
            During your trial, you can:
          </p>
          <ul style="color: #333; font-size: 14px; line-height: 1.8;">
            <li>🔒 Lock unlimited notes with biometric or PIN</li>
            <li>☁️ Sync notes across all your devices with end-to-end encryption</li>
          </ul>
          <p style="color: #666; font-size: 14px; line-height: 1.5;">
            We hope you enjoy using Better Keep! If you have any questions, reach out to us at <a href="mailto:support@betterkeep.app" style="color: #6750A4;">support@betterkeep.app</a>.
          </p>
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 12px;">
            Better Keep by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `,
		text: `
Welcome to Better Keep Pro! 🎉

Hi ${displayName},

Thank you for signing up! We've activated your free Pro trial so you can experience all the premium features.

Your trial expires on: ${expiryDateStr}

During your trial, you can:
- Lock unlimited notes with biometric or PIN
- Sync notes across all your devices with end-to-end encryption

We hope you enjoy using Better Keep! If you have any questions, reach out to us at support@betterkeep.app.

Better Keep by Foxbiz Software Pvt. Ltd.
    `,
	};

	await sendEmail(transporter, mailOptions);
}

/**
 * Scheduled function to check for expired trials and send notification emails.
 * Runs every hour to check for trials expiring soon or just expired.
 */
export const checkExpiredTrials = onSchedule(
	{
		schedule: "every 1 hours",
		secrets: [emailPassword],
	},
	async () => {
		console.log("Checking for expired trials...");

		try {
			const now = new Date();

			// Find trials that expired in the last hour and haven't been notified
			const oneHourAgo = new Date(now.getTime() - 60 * 60 * 1000);

			const expiredTrials = await db
				.collection("trialUsage")
				.where("trialExpiresAt", "<=", Timestamp.fromDate(now))
				.where("trialExpiresAt", ">", Timestamp.fromDate(oneHourAgo))
				.where("expiryEmailSent", "==", false)
				.get();

			// Also check trials without the expiryEmailSent field (legacy)
			const expiredTrialsLegacy = await db
				.collection("trialUsage")
				.where("trialExpiresAt", "<=", Timestamp.fromDate(now))
				.where("trialExpiresAt", ">", Timestamp.fromDate(oneHourAgo))
				.get();

			const allExpired = new Map<
				string,
				FirebaseFirestore.QueryDocumentSnapshot
			>();
			for (const doc of expiredTrials.docs) {
				allExpired.set(doc.id, doc);
			}
			for (const doc of expiredTrialsLegacy.docs) {
				const data = doc.data();
				if (data.expiryEmailSent !== true) {
					allExpired.set(doc.id, doc);
				}
			}

			console.log(`Found ${allExpired.size} expired trials to notify`);

			for (const [, doc] of allExpired) {
				const data = doc.data();
				const email = data.email;
				const userId = data.userId;

				if (!email || email === "unknown") continue;

				try {
					// Update subscription status to expired
					const userRef = db.collection("users").doc(userId);
					const subscriptionRef = userRef
						.collection("subscription")
						.doc("status");
					const subscriptionDoc = await subscriptionRef.get();

					if (
						subscriptionDoc.exists &&
						subscriptionDoc.data()?.source === "trial"
					) {
						await subscriptionRef.update({
							status: "expired",
							plan: "free",
							updatedAt: Timestamp.now(),
						});

						// Clear custom claims
						await setSubscriptionClaims(userId, "free", null);
					}

					// Send trial expired email
					await sendTrialExpiredEmail(email, data.displayName || "there");
					console.log(`Sent trial expired email to ${email}`);

					// Mark as notified
					await doc.ref.update({
						expiryEmailSent: true,
						expiryEmailSentAt: Timestamp.now(),
					});
				} catch (emailError) {
					console.error(
						`Failed to process expired trial for ${email}:`,
						emailError,
					);
				}
			}

			console.log("Expired trial check completed");
		} catch (error) {
			console.error("Error checking expired trials:", error);
		}
	},
);

/**
 * Send trial expired email
 */
async function sendTrialExpiredEmail(
	email: string,
	displayName: string,
): Promise<void> {
	const transporter = getEmailTransporter(emailPassword.value());
	const senderEmail = process.env.EMAIL_FROM;
	const senderName = process.env.EMAIL_NAME;

	const mailOptions = {
		from: `"${senderName}" <${senderEmail}>`,
		to: email,
		subject: "Your Better Keep Pro Trial Has Ended",
		html: `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
        <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
          <h1 style="color: #333; font-size: 24px; margin-bottom: 16px;">Your Pro Trial Has Ended</h1>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            Hi ${displayName},
          </p>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            Your Better Keep Pro trial has ended. We hope you enjoyed the premium features!
          </p>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            You can continue using Better Keep with the free plan, or upgrade to Pro to keep all the premium features:
          </p>
          <ul style="color: #333; font-size: 14px; line-height: 1.8;">
            <li>🔒 Unlimited locked notes</li>
            <li>☁️ Cloud sync across devices with end-to-end encryption</li>
          </ul>
          <div style="text-align: center; margin: 24px 0;">
            <a href="https://betterkeep.app/pricing" style="display: inline-block; background: linear-gradient(135deg, #6750A4 0%, #9C27B0 100%); color: white; text-decoration: none; padding: 14px 32px; border-radius: 8px; font-weight: 600; font-size: 16px;">
              Upgrade to Pro
            </a>
          </div>
          <p style="color: #666; font-size: 14px; line-height: 1.5;">
            Thank you for trying Better Keep Pro!
          </p>
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 12px;">
            Better Keep by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `,
		text: `
Your Better Keep Pro Trial Has Ended

Hi ${displayName},

Your Better Keep Pro trial has ended. We hope you enjoyed the premium features!

You can continue using Better Keep with the free plan, or upgrade to Pro to keep all the premium features:
- Unlimited locked notes
- Cloud sync across devices with end-to-end encryption

Upgrade at: https://betterkeep.app/pricing

Thank you for trying Better Keep Pro!

Better Keep by Foxbiz Software Pvt. Ltd.
    `,
	};

	await sendEmail(transporter, mailOptions);
}
