import { onRequest } from "firebase-functions/v2/https";
import { auth, isEmulator, oauthStateSecret } from "../config";
import {
	renderDesktopAppleSignIn,
	validateDesktopAppleCompletion,
} from "../desktopAppleAuth";
import { createOAuthCompletion } from "../oauthCompletion";
import {
	clearOAuthCookieHeader,
	createOpaqueToken,
	isClientTransactionId,
	isOpaqueToken,
	OAUTH_STATE_AUDIENCE,
	OAUTH_STATE_TTL_MS,
	type OAuthState,
	oauthCookieHeader,
	openOAuthState,
	readOAuthBrowserNonce,
	sealOAuthState,
} from "../oauthSession";
import { isProtectedReviewUserRecord } from "../reviewAccess";

export default onRequest(
	{ secrets: isEmulator ? [] : [oauthStateSecret] },
	async (req, res) => {
		res.set("Cache-Control", "no-store");
		res.set("Pragma", "no-cache");
		res.set("Referrer-Policy", "no-referrer");
		res.set("X-Content-Type-Options", "nosniff");
		if (req.method === "GET") {
			const {
				provider,
				mode,
				redirect,
				flowVersion,
				completionChallenge,
				clientTransactionId,
			} = req.query;
			if (
				provider !== "apple" ||
				mode !== "signin" ||
				redirect !== "betterkeep" ||
				flowVersion !== "2" ||
				!isOpaqueToken(completionChallenge) ||
				!isClientTransactionId(clientTransactionId)
			) {
				res.status(400).send("Invalid Apple sign-in request");
				return;
			}
			const now = Date.now();
			const state: OAuthState = {
				version: 2,
				audience: OAUTH_STATE_AUDIENCE,
				provider: "apple",
				mode: "signin",
				redirect: "betterkeep",
				completionChallenge,
				clientTransactionId,
				browserNonce: createOpaqueToken(),
				issuedAt: now,
				expiresAt: now + OAUTH_STATE_TTL_MS,
			};
			const page = renderDesktopAppleSignIn(
				await sealOAuthState(state, oauthStateSecret.value()),
				clientTransactionId,
			);
			res.set("Set-Cookie", oauthCookieHeader(state.browserNonce));
			res.set("Content-Security-Policy", page.contentSecurityPolicy);
			res.status(200).type("html").send(page.html);
			return;
		}
		if (req.method !== "POST") {
			res.set("Allow", "GET, POST");
			res.status(405).send("Method not allowed");
			return;
		}
		if (
			req.get("origin") !== "https://betterkeep.app" ||
			!req.is("application/json") ||
			typeof req.body?.state !== "string" ||
			typeof req.body?.idToken !== "string" ||
			req.body.state.length > 8192 ||
			req.body.idToken.length > 16384
		) {
			res.status(400).json({ error: "Invalid Apple sign-in completion" });
			return;
		}
		try {
			const state = await openOAuthState(
				req.body.state,
				oauthStateSecret.value(),
			);
			const token = await auth.verifyIdToken(req.body.idToken, true);
			validateDesktopAppleCompletion(
				state,
				readOAuthBrowserNonce(req.get("cookie")),
				token,
			);
			const { completionChallenge, clientTransactionId } = state;
			if (!completionChallenge || !clientTransactionId) {
				throw new Error("Invalid Apple sign-in completion");
			}
			if (isProtectedReviewUserRecord(await auth.getUser(token.uid))) {
				throw new Error("Apple sign-in is unavailable for this account");
			}
			const code = await createOAuthCompletion({
				uid: token.uid,
				provider: "apple",
				challenge: completionChallenge,
				clientTransactionId,
			});
			res.set("Set-Cookie", clearOAuthCookieHeader());
			res.status(200).json({ code });
		} catch {
			// Never log the submitted ID token, encrypted state or completion code.
			res.status(403).json({ error: "Apple sign-in is invalid or expired" });
		}
	},
);
