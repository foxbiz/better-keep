import assert from "node:assert/strict";
import test from "node:test";
import {
	parseOAuthHostingArguments,
	verifyOAuthHostingAttempt,
} from "../../scripts/verify_oauth_hosting.mjs";

function response(body, {headers = {}, status}) {
	return new Response(body, {headers, status});
}

test("OAuth Hosting verifier has safe production defaults", () => {
	assert.deepEqual(parseOAuthHostingArguments([]), {
		attempts: 10,
		baseUrl: "https://betterkeep.app",
		delayMillis: 2000,
	});
	assert.deepEqual(
		parseOAuthHostingArguments([
			"--url",
			"https://better-keep-notes.web.app/",
			"--attempts",
			"2",
			"--delay-ms",
			"0",
		]),
		{
			attempts: 2,
			baseUrl: "https://better-keep-notes.web.app",
			delayMillis: 0,
		},
	);
	assert.throws(
		() => parseOAuthHostingArguments(["--url", "http://betterkeep.app"]),
		/must use HTTPS/,
	);
	assert.throws(
		() => parseOAuthHostingArguments(["--attempts", "0"]),
		/positive integer/,
	);
});

test("OAuth Hosting verifier stops before GitHub and validates callback binding", async () => {
	const calls = [];
	const state = "sealed-oauth-state";
	const nonce = "n".repeat(43);
	const fetchImpl = async (url, options) => {
		calls.push({options, url: new URL(url)});
		if (calls.length === 1) {
			return response("", {
				headers: {
					location:
						`https://github.com/login/oauth/authorize?client_id=test&state=${state}`,
					"set-cookie":
						`__session=${nonce}; Max-Age=300; Path=/; Secure; HttpOnly; SameSite=Lax`,
				},
				status: 302,
			});
		}
		return response(
			"<!doctype html><p>Missing authorization code</p>",
			{
				headers: {"content-type": "text/html; charset=utf-8"},
				status: 400,
			},
		);
	};

	assert.deepEqual(
		await verifyOAuthHostingAttempt({
			baseUrl: "https://betterkeep.app",
			fetchImpl,
		}),
		{callbackStatus: 400, provider: "github"},
	);
	assert.equal(calls.length, 2);
	assert.equal(calls[0].options.redirect, "manual");
	assert.equal(calls[0].url.origin, "https://betterkeep.app");
	assert.equal(calls[0].url.pathname, "/oauth/start");
	assert.equal(calls[1].options.redirect, "manual");
	assert.equal(calls[1].url.origin, "https://betterkeep.app");
	assert.equal(calls[1].url.pathname, "/oauth/callback");
	assert.equal(calls[1].url.searchParams.get("state"), state);
	assert.equal(calls[1].url.searchParams.has("code"), false);
	assert.equal(calls[1].options.headers.Cookie, `__session=${nonce}`);
});

test("OAuth Hosting verifier rejects an unexpected authorization destination", async () => {
	await assert.rejects(
		verifyOAuthHostingAttempt({
			baseUrl: "https://betterkeep.app",
			fetchImpl: async () =>
				response("", {
					headers: {
						location: "https://attacker.example/authorize?state=unsafe",
						"set-cookie":
							`__session=${"n".repeat(43)}; Max-Age=300; Path=/; Secure; HttpOnly; SameSite=Lax`,
					},
					status: 302,
				}),
		}),
		/expected GitHub redirect/,
	);
});
