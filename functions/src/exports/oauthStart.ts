import * as crypto from "node:crypto";
import { onRequest } from "firebase-functions/v2/https";
import { facebookAppId, githubClientId, twitterClientId, twitterClientSecret } from '../config';
import type { OAuthState } from '../types';

/**
 * Start OAuth flow - redirects to provider's authorization page
 * URL: /oauthStart?provider=facebook&redirect=betterkeep&mode=signin
 * For linking: /oauthStart?provider=facebook&redirect=betterkeep&mode=link&uid=USER_UID
 */
export default onRequest(
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