import type * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import {
	auth,
	DEBUG_TRIAL_MINUTES,
	db,
	facebookAppId,
	facebookAppSecret,
	githubClientId,
	githubClientSecret,
	TRIAL_DAYS,
	TRIAL_ENABLED,
	twitterClientId,
	twitterClientSecret,
} from "../config";
import type { OAuthState } from "../types";
import { sendTrialWelcomeEmail } from "../utils";

/**
 * OAuth callback - exchanges code for tokens and creates Firebase user
 * This is called by OAuth providers after user authorizes
 */
export default onRequest(
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
			let userInfo: {
				id: string;
				email?: string;
				name?: string;
				photo?: string;
			};

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
			if (state.mode === "link" && state.linkingUserId) {
				// LINK MODE: User is already signed in, just link the provider

				// Verify the linking user exists
				try {
					await auth.getUser(state.linkingUserId);
				} catch {
					throw new Error("User not found. Please sign in again.");
				}

				// SECURITY: Verify OTP was verified before allowing link
				// This prevents bypassing OTP by directly calling OAuth URL
				const otpRef = db
					.collection("users")
					.doc(state.linkingUserId)
					.collection("otpVerification")
					.doc("accountLink");
				const otpDoc = await otpRef.get();

				if (!otpDoc.exists) {
					throw new Error(
						"Account link not authorized. Please verify your email first.",
					);
				}

				const otpData = otpDoc.data();
				if (!otpData?.verified) {
					throw new Error(
						"Account link not authorized. Please complete email verification first.",
					);
				}

				// Check OTP was verified for the same provider
				if (otpData.provider !== `${state.provider}.com`) {
					throw new Error(
						"Provider mismatch. Please start the linking process again.",
					);
				}

				// Check link token hasn't expired (2 minute window after OTP verification)
				const now = Timestamp.now();
				if (
					otpData.linkTokenExpires &&
					otpData.linkTokenExpires.toMillis() < now.toMillis()
				) {
					await otpRef.delete();
					throw new Error(
						"Link authorization expired. Please verify your email again.",
					);
				}

				// Check if this OAuth account is already linked to a different user
				if (userInfo.email) {
					try {
						const existingUser = await auth.getUserByEmail(userInfo.email);
						if (existingUser.uid !== state.linkingUserId) {
							throw new Error(
								`This ${state.provider} account is already associated with a different user. ` +
									`Please use a different ${state.provider} account.`,
							);
						}
					} catch (e) {
						// If error is not "user not found", it's our custom error - rethrow
						if (e instanceof Error && !e.message.includes("no user record")) {
							throw e;
						}
						// User not found by email is fine - it means OAuth account is not linked elsewhere
					}
				}

				// Check if provider is already linked to this user
				const userDoc = await db
					.collection("users")
					.doc(state.linkingUserId)
					.get();
				const linkedProviders = userDoc.data()?.linkedProviders || {};
				const existingProviderData = linkedProviders[state.provider];

				if (
					existingProviderData?.providerUid &&
					existingProviderData.providerUid !== userInfo.id
				) {
					throw new Error(
						`A different ${state.provider} account is already linked. ` +
							`Please unlink it first before linking a new one.`,
					);
				}

				// Store the linked provider in Firestore
				await db
					.collection("users")
					.doc(state.linkingUserId)
					.set(
						{
							linkedProviders: {
								[state.provider]: {
									providerUid: userInfo.id,
									linkedAt: FieldValue.serverTimestamp(),
									linkedVia: "oauth_link",
								},
							},
						},
						{ merge: true },
					);

				// Log the successful link for audit
				await db
					.collection("users")
					.doc(state.linkingUserId)
					.collection("auditLog")
					.add({
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
				if (state.redirect === "popup") {
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
						: localPart.slice(0, 2) +
							"*".repeat(Math.min(localPart.length - 2, 5));
				const domainParts = domain.split(".");
				const maskedDomain = domainParts
					.map((part, i) =>
						i === domainParts.length - 1
							? part // Keep TLD visible (.com, .org)
							: part.length <= 2
								? part[0] + "*"
								: part.slice(0, 2) + "*".repeat(Math.min(part.length - 2, 3)),
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
					(p) => p.providerId === providerDomain,
				);

				// Check 2: User document's linkedProviders (our custom linking)
				const userDoc = await db
					.collection("users")
					.doc(existingUser.uid)
					.get();
				const linkedProviders = userDoc.data()?.linkedProviders || {};
				const providerData = linkedProviders[state.provider];
				// Allow if: provider exists in linkedProviders AND (no providerUid OR providerUid matches)
				const hasProviderLinked =
					providerData &&
					(!providerData.providerUid ||
						providerData.providerUid === userInfo.id);

				// Check 3: User's original signup provider
				const signupProvider = userDoc.data()?.provider;
				const isOriginalProvider = signupProvider === state.provider;

				if (hasProviderInAuth || hasProviderLinked || isOriginalProvider) {
					// Allowed - user has this provider linked or signed up with it
					firebaseUser = existingUser;

					// Update linkedProviders with providerUid if missing (first login after OTP linking)
					if (!providerData?.providerUid) {
						await db
							.collection("users")
							.doc(existingUser.uid)
							.set(
								{
									linkedProviders: {
										[state.provider]: {
											providerUid: userInfo.id,
											linkedAt:
												providerData?.linkedAt || FieldValue.serverTimestamp(),
											linkedVia: providerData?.linkedVia || "oauth_login",
										},
									},
								},
								{ merge: true },
							);
					}
				} else {
					// SECURITY: Email exists but this provider is NOT linked
					throw new Error(
						`An account with email ${userInfo.email ? maskEmail(userInfo.email) : " ? "} already exists. ` +
							`Please sign in with your original login method, ` +
							`then link ${state.provider} from your account settings.`,
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
				await db
					.collection("users")
					.doc(firebaseUser.uid)
					.set(
						{
							email: userInfo.email || null,
							displayName: userInfo.name,
							photoURL: userInfo.photo,
							provider: state.provider,
							linkedProviders: {
								[state.provider]: {
									providerUid: userInfo.id,
									linkedAt: FieldValue.serverTimestamp(),
								},
							},
							createdAt: FieldValue.serverTimestamp(),
							lastSeen: FieldValue.serverTimestamp(),
						},
						{ merge: true },
					);

				// Grant trial for new users (blocking functions don't trigger for custom token auth)
				// This replicates the logic from grantTrialOnFirstSignIn
				if (TRIAL_ENABLED) {
					const email = userInfo.email?.trim()?.toLowerCase() || null;
					const emailKey = email || `no-email-${firebaseUser.uid}`;
					const trialRef = db.collection("trialUsage").doc(emailKey);
					const subscriptionRef = db
						.collection("users")
						.doc(firebaseUser.uid)
						.collection("subscription")
						.doc("status");

					// Check if email already used trial (for users who deleted and re-registered)
					const trialDoc = await trialRef.get();
					if (!trialDoc.exists) {
						// Calculate trial expiry
						const trialExpiresAt = new Date();
						if (DEBUG_TRIAL_MINUTES !== null) {
							trialExpiresAt.setMinutes(
								trialExpiresAt.getMinutes() + DEBUG_TRIAL_MINUTES,
							);
						} else {
							trialExpiresAt.setDate(trialExpiresAt.getDate() + TRIAL_DAYS);
						}

						console.log(
							`Granting trial to new OAuth user ${firebaseUser.uid}, expires ${trialExpiresAt.toISOString()}`,
						);

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
						console.log(
							`Email ${emailKey} already used trial, skipping for OAuth user ${firebaseUser.uid}`,
						);
					}
				}
			}

			// Create custom token
			const customToken = await auth.createCustomToken(firebaseUser.uid);

			// Handle different redirect modes
			if (state.redirect === "popup") {
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
			const errorMsg = e instanceof Error ? e.message : "Authentication failed";

			// Escape error message for HTML and JavaScript
			const htmlSafeError = errorMsg
				.replace(/&/g, "&amp;")
				.replace(/</g, "&lt;")
				.replace(/>/g, "&gt;")
				.replace(/"/g, "&quot;");
			const jsSafeError = errorMsg
				.replace(/\\/g, "\\\\")
				.replace(/'/g, "\\'")
				.replace(/"/g, '\\"');

			// Try to get state from query to determine if this was a popup request
			const stateParam = req.query.state as string | undefined;
			let isPopup = false;
			if (stateParam) {
				try {
					const state = JSON.parse(
						Buffer.from(stateParam, "base64").toString("utf-8"),
					);
					isPopup = state.redirect === "popup";
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
