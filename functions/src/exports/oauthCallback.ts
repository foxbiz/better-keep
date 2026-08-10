import type * as admin from "firebase-admin";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { consumeAccountLinkSession } from "../accountLinkSession";
import {
	auth,
	db,
	facebookAppId,
	facebookAppSecret,
	githubClientId,
	githubClientSecret,
	isEmulator,
	legacyOAuthV1Enabled,
	oauthStateSecret,
	twitterClientId,
	twitterClientSecret,
} from "../config";
import { createOAuthCompletion } from "../oauthCompletion";
import {
	clearOAuthCookieHeader,
	openOAuthState,
	readOAuthBrowserNonce,
	timingSafeStringEqual,
	type OAuthState,
} from "../oauthSession";
import {
	renderOAuthMobileRedirect,
	renderOAuthPopup,
	type RenderedOAuthHtml,
} from "../oauthResponse";
import {
	isProtectedReviewUserRecord,
	isReviewAccountEmail,
} from "../reviewAccess";
import { grantTrialIfEligible } from "../trialGrant";

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
			...(isEmulator ? [] : [oauthStateSecret]),
		],
	},
	async (req, res) => {
		res.set("Cache-Control", "no-store");
		res.set("Pragma", "no-cache");
		res.set("Referrer-Policy", "no-referrer");

		if (req.method !== "GET") {
			res.set("Allow", "GET");
			res.status(405).send("Method not allowed");
			return;
		}

		const code =
			typeof req.query.code === "string" ? req.query.code : undefined;
		const sealedState =
			typeof req.query.state === "string" ? req.query.state : undefined;
		const error =
			typeof req.query.error === "string" ? req.query.error : undefined;

		const sendHtml = (rendered: RenderedOAuthHtml, status = 200) => {
			res.set("Content-Security-Policy", rendered.contentSecurityPolicy);
			res.set("X-Content-Type-Options", "nosniff");
			res.status(status).type("html").send(rendered.html);
		};

		const sendError = (errorMsg: string, state?: OAuthState) => {
			if (state?.redirect === "popup" && state.clientOrigin) {
				sendHtml(
					renderOAuthPopup({
						title: "Sign In Failed - Better Keep",
						heading: "Sign In Failed",
						message: errorMsg,
						success: false,
						targetOrigin: state.clientOrigin,
						payload: {
							type: "oauth_error",
							error: errorMsg,
							transactionId: state.clientTransactionId,
						},
					}),
					400,
				);
			} else if (state?.redirect === "betterkeep") {
				const query = new URLSearchParams({
					error: errorMsg,
					...(state.clientTransactionId
						? { transactionId: state.clientTransactionId }
						: {}),
				});
				sendHtml(
					renderOAuthMobileRedirect({
						title: "Sign In Failed - Better Keep",
						heading: "Sign In Failed",
						message: errorMsg,
						success: false,
						redirectUrl: `betterkeep://auth?${query.toString()}`,
					}),
					400,
				);
			} else {
				res.status(400).type("text").send("OAuth authentication failed");
			}
		};

		let state: OAuthState | undefined;
		if (!sealedState) {
			console.warn(
				JSON.stringify({
					event: "oauth_state_rejected",
					reason: "missing_state",
				}),
			);
		} else {
			let opened: OAuthState | undefined;
			try {
				opened = await openOAuthState(
					sealedState,
					oauthStateSecret.value(),
				);
			} catch {
				console.warn(
					JSON.stringify({
						event: "oauth_state_rejected",
						reason: "invalid_or_expired_state",
					}),
				);
			}

			if (opened) {
				const cookieNonce = readOAuthBrowserNonce(req.get("cookie"));
				if (!cookieNonce) {
					console.warn(
						JSON.stringify({
							event: "oauth_state_rejected",
							reason: "missing_browser_cookie",
						}),
					);
				} else if (!timingSafeStringEqual(cookieNonce, opened.browserNonce)) {
					console.warn(
						JSON.stringify({
							event: "oauth_state_rejected",
							reason: "browser_cookie_mismatch",
						}),
					);
				} else {
					state = opened;
				}
			}
		}
		res.set("Set-Cookie", clearOAuthCookieHeader());

		// Handle OAuth errors (user denied, etc.)
		if (error) {
			const errorDesc =
				(req.query.error_description as string) || "Authorization failed";
			sendError(errorDesc, state);
			return;
		}

		if (!code || !sealedState) {
			sendError("Missing authorization code", state);
			return;
		}

		if (!state) {
			sendError("Invalid state");
			return;
		}
		if (state.version === 1 && !legacyOAuthV1Enabled) {
			sendError("Update Better Keep to complete OAuth sign-in", state);
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
					const codeVerifier = state.codeVerifier;
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
			if (state.mode === "link" && state.linkingUserId && state.linkSessionId) {
				// LINK MODE: User is already signed in, just link the provider

				// Verify the linking user exists
				let linkingUser: admin.auth.UserRecord;
				try {
					linkingUser = await auth.getUser(state.linkingUserId);
				} catch {
					throw new Error("User not found. Please sign in again.");
				}
				if (isProtectedReviewUserRecord(linkingUser)) {
					throw new Error("Account linking is unavailable");
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
				const userRef = db.collection("users").doc(state.linkingUserId);
				const userDoc = await userRef.get();
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

				const otpRef = userRef.collection("otpVerification").doc("accountLink");
				const auditRef = userRef.collection("auditLog").doc();
				const linkSessionRef = db
					.collection("accountLinkSessions")
					.doc(state.linkSessionId);

				// Consume the one-time authorization and commit link metadata
				// atomically so neither can succeed without the other.
				await consumeAccountLinkSession({
					db,
					sessionRef: linkSessionRef,
					expectation: {
						uid: state.linkingUserId,
						provider: `${state.provider}.com`,
					},
					consumedAt: Timestamp.now(),
					onConsume: (transaction) => {
						transaction.set(
							userRef,
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
						transaction.set(auditRef, {
							action: "account_linked",
							provider: state.provider,
							providerUid: userInfo.id,
							timestamp: FieldValue.serverTimestamp(),
							success: true,
						});
						transaction.delete(otpRef);
					},
				});

				console.info(
					JSON.stringify({
						event: "oauth_account_linked",
						flowVersion: state.version,
						provider: state.provider,
						redirect: state.redirect,
					}),
				);

				if (state.redirect === "popup" && state.clientOrigin) {
					sendHtml(
						renderOAuthPopup({
							title: "Account Linked - Better Keep",
							heading: "Account Linked",
							message: "You can return to Better Keep.",
							success: true,
							targetOrigin: state.clientOrigin,
							payload: {
								type: "oauth_link_success",
								provider: state.provider,
								transactionId: state.clientTransactionId,
							},
						}),
					);
				} else {
					const query = new URLSearchParams({
						linked: "true",
						provider: state.provider,
						...(state.clientTransactionId
							? { transactionId: state.clientTransactionId }
							: {}),
					});
					sendHtml(
						renderOAuthMobileRedirect({
							title: "Account Linked - Better Keep",
							heading: "Account Linked",
							message: "Returning to Better Keep…",
							success: true,
							redirectUrl: `betterkeep://auth?${query.toString()}`,
						}),
					);
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
						? `${localPart[0]}*`
						: localPart.slice(0, 2) +
							"*".repeat(Math.min(localPart.length - 2, 5));
				const domainParts = domain.split(".");
				const maskedDomain = domainParts
					.map((part, i) =>
						i === domainParts.length - 1
							? part // Keep TLD visible (.com, .org)
							: part.length <= 2
								? `${part[0]}*`
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

			if (
				isReviewAccountEmail(userInfo.email) ||
				isProtectedReviewUserRecord(existingUser)
			) {
				throw new Error(
					"The managed review account only supports password sign-in.",
				);
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

				await grantTrialIfEligible({
					user: firebaseUser,
					persistCustomClaims: true,
				}).catch((error) =>
					console.error(
						"OAuth trial grant failed without blocking sign-in",
						error,
					),
				);
			}

			let popupPayload: Record<string, unknown>;
			let mobileQuery: URLSearchParams;
			if (state.version === 2) {
				const completionCode = await createOAuthCompletion({
					uid: firebaseUser.uid,
					provider: state.provider,
					challenge: state.completionChallenge as string,
					clientTransactionId: state.clientTransactionId as string,
				});
				popupPayload = {
					type: "oauth_success",
					completionCode,
					provider: state.provider,
					transactionId: state.clientTransactionId,
				};
				mobileQuery = new URLSearchParams({
					code: completionCode,
					provider: state.provider,
					transactionId: state.clientTransactionId as string,
				});
			} else {
				// Compatibility path for already released clients. This path is
				// intentionally isolated and must be removed at the v1 sunset.
				const customToken = await auth.createCustomToken(firebaseUser.uid);
				popupPayload = {
					type: "oauth_success",
					token: customToken,
					provider: state.provider,
				};
				mobileQuery = new URLSearchParams({
					token: customToken,
					provider: state.provider,
				});
			}

			console.info(
				JSON.stringify({
					event: "oauth_flow_completed",
					flowVersion: state.version,
					provider: state.provider,
					mode: state.mode,
					redirect: state.redirect,
				}),
			);

			if (state.redirect === "popup" && state.clientOrigin) {
				sendHtml(
					renderOAuthPopup({
						title: "Sign In Successful - Better Keep",
						heading: "Sign In Successful",
						message: "Completing sign-in…",
						success: true,
						targetOrigin: state.clientOrigin,
						payload: popupPayload,
					}),
				);
			} else {
				sendHtml(
					renderOAuthMobileRedirect({
						title: "Sign In Successful - Better Keep",
						heading: "Sign In Successful",
						message: "Returning to Better Keep…",
						success: true,
						redirectUrl: `betterkeep://auth?${mobileQuery.toString()}`,
					}),
				);
			}
		} catch (error) {
			console.error(
				JSON.stringify({
					event: "oauth_flow_failed",
					flowVersion: state.version,
					provider: state.provider,
					mode: state.mode,
					redirect: state.redirect,
				}),
			);
			const errorMsg =
				error instanceof Error ? error.message : "Authentication failed";
			sendError(errorMsg, state);
		}
	},
);
