import { onRequest } from "firebase-functions/v2/https";
import { isValidAccountLinkSession } from "../accountLinkSession";
import {
	auth,
	db,
	facebookAppId,
	githubClientId,
	isEmulator,
	legacyOAuthV1Enabled,
	oauthStateSecret,
	twitterClientId,
	twitterClientSecret,
} from "../config";
import {
	accountProviderFor,
	challengeForVerifier,
	createOpaqueToken,
	hashOpaqueToken,
	isAllowedOAuthClientOrigin,
	isClientTransactionId,
	isCustomOAuthProvider,
	isOpaqueToken,
	OAUTH_STATE_TTL_MS,
	OAUTH_STATE_AUDIENCE,
	oauthCookieHeader,
	originFromReferrer,
	parseOAuthMode,
	parseOAuthRedirect,
	sealOAuthState,
	type OAuthFlowVersion,
	type OAuthState,
} from "../oauthSession";
import { isProtectedReviewUserRecord } from "../reviewAccess";

const CALLBACK_URL = "https://betterkeep.app/oauth/callback";

/**
 * Starts a custom OAuth transaction.
 *
 * State is encrypted and bound to the browser that initiated the flow. No
 * anonymous Firestore state document is created.
 */
export default onRequest(
	{
		secrets: [
			facebookAppId,
			githubClientId,
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

		const providerValue = req.query.provider;
		const redirect = parseOAuthRedirect(req.query.redirect);
		const mode = parseOAuthMode(req.query.mode);
		const flowVersionValue = req.query.flowVersion;
		const version: OAuthFlowVersion =
			flowVersionValue === undefined || flowVersionValue === "" ? 1 : 2;

		if (
			flowVersionValue !== undefined &&
			flowVersionValue !== "" &&
			flowVersionValue !== "2"
		) {
			res.status(400).send("Unsupported OAuth flow version");
			return;
		}
		if (version === 1 && !legacyOAuthV1Enabled) {
			res
				.status(426)
				.send("This app version must be updated before using OAuth sign-in");
			return;
		}
		if (!isCustomOAuthProvider(providerValue)) {
			res.status(400).send("Invalid provider");
			return;
		}
		if (!redirect || !mode) {
			res.status(400).send("Invalid OAuth redirect or mode");
			return;
		}

		let clientOrigin: string | undefined;
		if (redirect === "popup") {
			const requestedOrigin =
				typeof req.query.clientOrigin === "string"
					? req.query.clientOrigin
					: undefined;
			clientOrigin =
				version === 2
					? requestedOrigin
					: (originFromReferrer(req.get("referer"), isEmulator) ?? undefined);
			if (!isAllowedOAuthClientOrigin(clientOrigin, isEmulator)) {
				res.status(403).send("OAuth client origin is not allowed");
				return;
			}
		}

		let clientTransactionId: string | undefined;
		let completionChallenge: string | undefined;
		if (version === 2) {
			clientTransactionId =
				typeof req.query.clientTransactionId === "string"
					? req.query.clientTransactionId
					: undefined;
			completionChallenge =
				typeof req.query.completionChallenge === "string"
					? req.query.completionChallenge
					: undefined;
			if (
				!isClientTransactionId(clientTransactionId) ||
				!isOpaqueToken(completionChallenge)
			) {
				res.status(400).send("Invalid OAuth completion challenge");
				return;
			}
		}

		let linkingUserId: string | undefined;
		let linkSessionId: string | undefined;
		if (mode === "link") {
			const linkToken = req.query.linkToken;
			if (!isOpaqueToken(linkToken)) {
				res.status(400).send("Missing account-link authorization");
				return;
			}

			linkSessionId = hashOpaqueToken(linkToken);
			const linkSession = await db
				.collection("accountLinkSessions")
				.doc(linkSessionId)
				.get();
			const linkData = linkSession.data();
			const expectedProvider = accountProviderFor(providerValue);
			if (
				!linkSession.exists ||
				!isValidAccountLinkSession(linkData, {
					provider: expectedProvider,
				})
			) {
				res
					.status(403)
					.send("Account-link authorization is invalid or expired");
				return;
			}

			const linkingUser = await auth.getUser(linkData.uid);
			if (isProtectedReviewUserRecord(linkingUser)) {
				res.status(403).send("Account linking is unavailable");
				return;
			}
			linkingUserId = linkingUser.uid;
		}

		const now = Date.now();
		const browserNonce = createOpaqueToken();
		const codeVerifier =
			providerValue === "twitter" ? createOpaqueToken() : undefined;
		const state: OAuthState = {
			version,
			audience: OAUTH_STATE_AUDIENCE,
			provider: providerValue,
			redirect,
			mode,
			linkingUserId,
			linkSessionId,
			codeVerifier,
			clientOrigin,
			clientTransactionId,
			completionChallenge,
			browserNonce,
			issuedAt: now,
			expiresAt: now + OAUTH_STATE_TTL_MS,
		};
		const sealedState = await sealOAuthState(state, oauthStateSecret.value());

		res.set("Set-Cookie", oauthCookieHeader(browserNonce));
		console.info(
			JSON.stringify({
				event: "oauth_flow_started",
				flowVersion: version,
				provider: providerValue,
				mode,
				redirect,
			}),
		);

		let authUrl: string;
		switch (providerValue) {
			case "facebook":
				authUrl =
					"https://www.facebook.com/v18.0/dialog/oauth?" +
					`client_id=${facebookAppId.value()}` +
					`&redirect_uri=${encodeURIComponent(CALLBACK_URL)}` +
					`&state=${encodeURIComponent(sealedState)}` +
					"&scope=email,public_profile";
				break;
			case "github":
				authUrl =
					"https://github.com/login/oauth/authorize?" +
					`client_id=${githubClientId.value()}` +
					`&redirect_uri=${encodeURIComponent(CALLBACK_URL)}` +
					`&state=${encodeURIComponent(sealedState)}` +
					"&scope=read:user,user:email";
				break;
			case "twitter":
				authUrl =
					"https://twitter.com/i/oauth2/authorize?" +
					`client_id=${twitterClientId.value()}` +
					`&redirect_uri=${encodeURIComponent(CALLBACK_URL)}` +
					`&state=${encodeURIComponent(sealedState)}` +
					"&scope=tweet.read%20users.read%20offline.access" +
					"&response_type=code" +
					`&code_challenge=${challengeForVerifier(codeVerifier as string)}` +
					"&code_challenge_method=S256";
				break;
		}

		res.redirect(authUrl);
	},
);
