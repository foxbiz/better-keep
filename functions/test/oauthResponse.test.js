const assert = require("node:assert/strict");
const test = require("node:test");
const {
	renderOAuthMobileRedirect,
	renderOAuthPopup,
} = require("../lib/oauthResponse");

test("popup response pins both message directions to the exact origin", () => {
	const response = renderOAuthPopup({
		title: "Done",
		heading: "Done",
		message: "Return to the app",
		success: true,
		targetOrigin: "https://betterkeep.app",
		payload: {
			type: "oauth_success",
			completionCode: "opaque",
			transactionId: "transaction",
		},
	});
	assert.match(
		response.html,
		/postMessage\(payload, targetOrigin\)/,
	);
	assert.match(response.html, /event\.origin === targetOrigin/);
	assert.match(response.html, /event\.source === window\.opener/);
	assert.doesNotMatch(response.html, /postMessage\([^)]*,\s*["']\*["']/);
	assert.match(response.contentSecurityPolicy, /default-src 'none'/);
});

test("dynamic values cannot terminate callback scripts", () => {
	const hostile = "</script><script>alert(1)</script>";
	const popup = renderOAuthPopup({
		title: "Failed",
		heading: "Failed",
		message: hostile,
		success: false,
		targetOrigin: "https://betterkeep.app",
		payload: { type: "oauth_error", error: hostile },
	});
	const mobile = renderOAuthMobileRedirect({
		title: "Failed",
		heading: "Failed",
		message: hostile,
		success: false,
		redirectUrl: `betterkeep://auth?error=${encodeURIComponent(hostile)}`,
	});
	assert.doesNotMatch(popup.html, /<script>alert\(1\)<\/script>/);
	assert.doesNotMatch(mobile.html, /<script>alert\(1\)<\/script>/);
	assert.match(popup.html, /\\u003c\/script>/);
});
