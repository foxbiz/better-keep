const { test } = require("node:test");
const assert = require("node:assert/strict");
const {
	exchangeOAuthToken,
	parseOAuthTokenInput,
	OAuthExchangeError,
} = require("../lib/oauthTokenExchange");
const provider = {
	clientId: "client",
	clientSecret: "server-only-secret",
	tokenEndpoint: "https://oauth.example.test/token",
	redirectUris: ["https://app.example.test/oauth/storage/callback"],
};
const code = {
	operation: "code",
	clientId: "client",
	code: "one-time-code",
	verifier: "a".repeat(43),
	redirectUri: provider.redirectUris[0],
};
const refresh = {
	operation: "refresh",
	clientId: "client",
	refreshToken: "refresh-secret",
};
const response = {
	access_token: "access-secret",
	refresh_token: "rotated-secret",
	token_type: "Bearer",
	expires_in: 3600,
};
test("generic code and refresh transport sends only fixed fields and normalizes response", async () => {
	for (const input of [code, refresh]) {
		const result = await exchangeOAuthToken(
			provider,
			parseOAuthTokenInput(input),
			async (url, options) => {
				assert.equal(url.href, provider.tokenEndpoint);
				assert.equal(options.redirect, "error");
				assert.equal(options.body.get("client_secret"), provider.clientSecret);
				assert.equal(
					options.body.get("grant_type"),
					input.operation === "code" ? "authorization_code" : "refresh_token",
				);
				assert.equal(
					options.body.get("code_verifier"),
					input.operation === "code" ? code.verifier : null,
				);
				return Response.json({
					...response,
					scope: "not-persisted",
					extra: "not-returned",
				});
			},
			() => 1000,
		);
		assert.deepEqual(result, {
			type: "oauth",
			accessToken: "access-secret",
			refreshToken: "rotated-secret",
			expiresAt: 3601000,
		});
	}
});
test("mismatched client and unregistered callback never make a network request", async () => {
	for (const input of [
		{ ...code, clientId: "other" },
		{ ...code, redirectUri: "https://attacker.test/callback" },
	]) {
		await assert.rejects(
			exchangeOAuthToken(provider, input, () => assert.fail("network")),
			/invalid/,
		);
	}
});
test("malformed inputs and unsupported operations are rejected", () => {
	for (const input of [
		{ ...code, verifier: "short" },
		{ ...code, code: "bad\ncode" },
		{ ...refresh, refreshToken: "" },
		{ ...refresh, operation: "password" },
	])
		assert.throws(() => parseOAuthTokenInput(input), /invalid/);
});
test("provider errors and thrown transport errors never disclose response credentials", async () => {
	for (const status of [400, 401, 429, 500, 302]) {
		await assert.rejects(
			exchangeOAuthToken(
				provider,
				refresh,
				async () => new Response("SECRET details", { status }),
			),
			(e) => e instanceof OAuthExchangeError && !e.message.includes("SECRET"),
		);
	}
	await assert.rejects(
		exchangeOAuthToken(provider, refresh, async () => {
			throw Error("SECRET transport");
		}),
		(e) => e.message === "OAuth exchange unavailable",
	);
});
test("refresh may omit rotation; initial consent must supply a reusable refresh token", async () => {
	const reply = { ...response };
	delete reply.refresh_token;
	assert.equal(
		(
			await exchangeOAuthToken(provider, refresh, async () =>
				Response.json(reply),
			)
		).refreshToken,
		undefined,
	);
	await assert.rejects(
		exchangeOAuthToken(provider, code, async () => Response.json(reply)),
		/reconnect_required/,
	);
});
test("malformed, oversized and invalid token responses are rejected", async () => {
	for (const reply of [
		null,
		{ ...response, expires_in: Infinity },
		{ ...response, expires_in: -1 },
		{ ...response, token_type: "mac" },
		{ ...response, access_token: "" },
	])
		await assert.rejects(
			exchangeOAuthToken(provider, code, async () => Response.json(reply)),
			OAuthExchangeError,
		);
	await assert.rejects(
		exchangeOAuthToken(
			provider,
			code,
			async () => new Response("x".repeat(65537)),
		),
		/unavailable/,
	);
});
