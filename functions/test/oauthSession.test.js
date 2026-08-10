const assert = require("node:assert/strict");
const test = require("node:test");
const {
	accountProviderFor,
	challengeForVerifier,
	clearOAuthCookieHeader,
	createClientTransactionId,
	createOpaqueToken,
	hashOpaqueToken,
	isAllowedOAuthClientOrigin,
	isClientTransactionId,
	isCustomOAuthProvider,
	isOpaqueToken,
	OAUTH_BROWSER_COOKIE,
	OAUTH_STATE_AUDIENCE,
	oauthCookieHeader,
	openOAuthState,
	parseOAuthMode,
	parseOAuthRedirect,
	readOAuthBrowserNonce,
	sealOAuthState,
	timingSafeStringEqual,
} = require("../lib/oauthSession");

test("custom OAuth providers are allowlisted", () => {
	for (const provider of ["facebook", "github", "twitter"]) {
		assert.equal(isCustomOAuthProvider(provider), true);
	}
	for (const provider of ["google", "apple", "facebook.com", "", undefined]) {
		assert.equal(isCustomOAuthProvider(provider), false);
	}
	assert.equal(accountProviderFor("github"), "github.com");
});

test("OAuth mode and redirect are allowlisted", () => {
	assert.equal(parseOAuthMode(undefined), "signin");
	assert.equal(parseOAuthMode("signin"), "signin");
	assert.equal(parseOAuthMode("link"), "link");
	assert.equal(parseOAuthMode("delete"), null);

	assert.equal(parseOAuthRedirect(undefined), "betterkeep");
	assert.equal(parseOAuthRedirect("popup"), "popup");
	assert.equal(parseOAuthRedirect("betterkeep"), "betterkeep");
	assert.equal(parseOAuthRedirect("https://attacker.example"), null);
});

test("opaque tokens are random and hash deterministically", () => {
	const first = createOpaqueToken();
	const second = createOpaqueToken();

	assert.notEqual(first, second);
	assert.match(first, /^[A-Za-z0-9_-]{43}$/);
	assert.equal(isOpaqueToken(first), true);
	assert.equal(isOpaqueToken(`${first}extra`), false);
	assert.equal(isOpaqueToken("../invalid"), false);
	assert.equal(hashOpaqueToken(first), hashOpaqueToken(first));
	assert.notEqual(hashOpaqueToken(first), hashOpaqueToken(second));
	assert.match(hashOpaqueToken(first), /^[a-f0-9]{64}$/);
	assert.equal(challengeForVerifier(first).length, 43);
	assert.equal(timingSafeStringEqual(first, first), true);
	assert.equal(timingSafeStringEqual(first, second), false);
	const transactionId = createClientTransactionId();
	assert.equal(isClientTransactionId(transactionId), true);
	assert.equal(isClientTransactionId(first), false);
});

test("OAuth client origins are exact and emulator origins stay local", () => {
	assert.equal(
		isAllowedOAuthClientOrigin("https://betterkeep.app", false),
		true,
	);
	assert.equal(
		isAllowedOAuthClientOrigin("https://betterkeep.app.evil.test", false),
		false,
	);
	assert.equal(
		isAllowedOAuthClientOrigin("http://localhost:63630", false),
		false,
	);
	assert.equal(
		isAllowedOAuthClientOrigin("http://localhost:63630", true),
		true,
	);
});

test("OAuth state is encrypted, authenticated, expiring, and cookie-bound", async () => {
	const now = Date.now();
	const secret = Buffer.alloc(32, 7).toString("base64url");
	const browserNonce = createOpaqueToken();
	const state = {
		version: 2,
		audience: OAUTH_STATE_AUDIENCE,
		provider: "github",
		redirect: "popup",
		mode: "signin",
		clientOrigin: "https://betterkeep.app",
		clientTransactionId: createClientTransactionId(),
		completionChallenge: createOpaqueToken(),
		browserNonce,
		issuedAt: now,
		expiresAt: now + 60_000,
	};
	const sealed = await sealOAuthState(state, secret);
	assert.equal(sealed.includes("github"), false);
	assert.deepEqual(await openOAuthState(sealed, secret, now + 1), state);

	const parts = sealed.split(".");
	parts[3] = `${parts[3].startsWith("a") ? "b" : "a"}${parts[3].slice(1)}`;
	const tampered = parts.join(".");
	await assert.rejects(openOAuthState(tampered, secret, now + 1));
	await assert.rejects(openOAuthState(sealed, secret, now + 60_001));
	await assert.rejects(
		openOAuthState(sealed, Buffer.alloc(32, 8).toString("base64url"), now + 1),
	);
	const wrongAudience = await sealOAuthState(
		{ ...state, audience: "other-service" },
		secret,
	);
	await assert.rejects(openOAuthState(wrongAudience, secret, now + 1));

	const cookie = oauthCookieHeader(browserNonce);
	assert.equal(OAUTH_BROWSER_COOKIE, "__session");
	assert.equal(
		cookie,
		`__session=${browserNonce}; Max-Age=300; Path=/; Secure; HttpOnly; SameSite=Lax`,
	);
	assert.equal(
		readOAuthBrowserNonce(`other=value; ${cookie.split(";")[0]}`),
		browserNonce,
	);
	assert.equal(
		readOAuthBrowserNonce(`__Host-bk-oauth=${browserNonce}`),
		null,
	);
	assert.doesNotMatch(cookie, /Domain=/i);
	assert.equal(
		clearOAuthCookieHeader(),
		"__session=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax",
	);
});
