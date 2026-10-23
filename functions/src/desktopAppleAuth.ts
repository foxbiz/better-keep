import { randomBytes } from "node:crypto";
import type { DecodedIdToken } from "firebase-admin/auth";
import { timingSafeStringEqual, type OAuthState } from "./oauthSession";
import type { RenderedOAuthHtml } from "./oauthResponse";

export function validateDesktopAppleCompletion(
	state: OAuthState,
	browserNonce: string | null,
	token: DecodedIdToken,
): void {
	if (
		state.provider !== "apple" ||
		state.version !== 2 ||
		state.mode !== "signin" ||
		state.redirect !== "betterkeep" ||
		!browserNonce ||
		!timingSafeStringEqual(browserNonce, state.browserNonce) ||
		token.firebase?.sign_in_provider !== "apple.com" ||
		!Number.isFinite(token.auth_time) ||
		token.auth_time * 1000 < state.issuedAt - 30_000
	) {
		throw new Error("Invalid Apple sign-in completion");
	}
}

// Firebase handles Apple's keys, redirect URI, account identity and nonce.
// The browser session stays in memory; only a verifier-bound completion code
// is returned to Windows, never a Firebase ID token or custom token.
export function renderDesktopAppleSignIn(
	state: string,
	transactionId: string,
): RenderedOAuthHtml {
	const nonce = randomBytes(18).toString("base64");
	const data = JSON.stringify({ state, transactionId }).replace(
		/</g,
		"\\u003c",
	);
	return {
		contentSecurityPolicy:
			"default-src 'none'; " +
			`script-src 'nonce-${nonce}' https://www.gstatic.com https://apis.google.com; ` +
			`style-src 'nonce-${nonce}'; ` +
			"connect-src 'self' https://*.googleapis.com; " +
			"frame-src 'self' https://*.firebaseapp.com; " +
			"base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
		html: `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Sign in with Apple - Better Keep</title>
<style nonce="${nonce}">
body { font-family: system-ui, sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #faf8ff; color: #252129; }
main { max-width: 380px; padding: 32px; text-align: center; }
button, a { display: block; margin: 18px auto; padding: 14px 24px; border-radius: 8px; }
button { background: #171717; color: white; border: 0; font: inherit; cursor: pointer; }
button:disabled { opacity: .5; } a { color: #6750a4; } [hidden] { display: none; }
</style></head><body><main><h1>Sign in to Better Keep</h1>
<p id="status" role="status">Preparing Apple sign-in…</p>
<button id="signin" disabled>Continue with Apple</button>
<a id="return" hidden>Return to Better Keep</a>
<a id="cancel">Cancel</a></main>
<script type="module" nonce="${nonce}">
import { initializeApp } from 'https://www.gstatic.com/firebasejs/12.16.0/firebase-app.js';
import { initializeAuth, inMemoryPersistence, browserPopupRedirectResolver, OAuthProvider, signInWithPopup, signOut } from 'https://www.gstatic.com/firebasejs/12.16.0/firebase-auth.js';
const { state, transactionId } = ${data};
const button = document.getElementById('signin');
const status = document.getElementById('status');
const back = document.getElementById('return');
const cancel = document.getElementById('cancel');
cancel.href = 'betterkeep://auth?' + new URLSearchParams({ transactionId, cancelled: 'true' });
function returnToApp(url) {
  back.href = url;
  back.hidden = false;
  button.hidden = true;
  cancel.hidden = true;
  status.textContent = 'You can now return to Better Keep.';
  window.location.assign(url);
}
try {
  const response = await fetch('/__/firebase/init.json', { cache: 'no-store' });
  if (!response.ok) throw new Error('Could not load sign-in configuration. Please try again.');
  // Hosting returns firebaseapp.com; Apple is configured for our custom domain.
  const config = { ...await response.json(), authDomain: 'betterkeep.app' };
  const auth = initializeAuth(initializeApp(config), {
    persistence: inMemoryPersistence, popupRedirectResolver: browserPopupRedirectResolver
  });
  const provider = new OAuthProvider('apple.com');
  provider.addScope('email');
  provider.addScope('name');
  status.textContent = 'Continue with Apple to sign in to the Windows app.';
  button.disabled = false;
  button.onclick = async () => {
    button.disabled = true;
    try {
      const result = await signInWithPopup(auth, provider);
      status.textContent = 'Returning to Better Keep…';
      const completion = await fetch('/oauth/apple', {
        method: 'POST', credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ state, idToken: await result.user.getIdToken() })
      });
      if (!completion.ok) throw new Error('Sign-in expired or could not be completed. Please try again from the app.');
      const { code } = await completion.json();
      await signOut(auth).catch(() => {});
      returnToApp('betterkeep://auth?' + new URLSearchParams({ transactionId, code }));
    } catch (error) {
      await signOut(auth).catch(() => {});
      if (error.code === 'auth/popup-closed-by-user' || error.code === 'auth/cancelled-popup-request') {
        returnToApp(cancel.href);
      } else {
        status.textContent = error.message || 'Apple sign-in failed. Please try again.';
        button.disabled = false;
      }
    }
  };
} catch (error) {
  status.textContent = error.message || 'Could not prepare Apple sign-in. Please try again from the app.';
}
</script></body></html>`,
	};
}
