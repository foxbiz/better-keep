#!/usr/bin/env node

import {randomBytes} from "node:crypto";
import path from "node:path";
import {fileURLToPath} from "node:url";

const runnerPath = fileURLToPath(import.meta.url);

const DEFAULT_BASE_URL = "https://betterkeep.app";
const DEFAULT_ATTEMPTS = 10;
const DEFAULT_DELAY_MILLIS = 2000;

function createTransactionId() {
	return randomBytes(16).toString("base64url");
}

function createCompletionChallenge() {
	return randomBytes(32).toString("base64url");
}

function wait(delayMillis) {
	return new Promise((resolve) => setTimeout(resolve, delayMillis));
}

export function parseOAuthHostingArguments(argv) {
	const options = {
		attempts: DEFAULT_ATTEMPTS,
		baseUrl: DEFAULT_BASE_URL,
		delayMillis: DEFAULT_DELAY_MILLIS,
	};
	for (let index = 0; index < argv.length; index += 2) {
		const key = argv[index];
		const value = argv[index + 1];
		if (!value) throw new Error(`${key} requires a value.`);
		if (key === "--attempts") options.attempts = Number(value);
		else if (key === "--delay-ms") options.delayMillis = Number(value);
		else if (key === "--url") options.baseUrl = value;
		else throw new Error(`Unknown OAuth Hosting verification option: ${key}`);
	}
	if (!Number.isInteger(options.attempts) || options.attempts < 1) {
		throw new Error("--attempts must be a positive integer.");
	}
	if (!Number.isInteger(options.delayMillis) || options.delayMillis < 0) {
		throw new Error("--delay-ms must be a non-negative integer.");
	}

	const baseUrl = new URL(options.baseUrl);
	if (baseUrl.protocol !== "https:") {
		throw new Error("--url must use HTTPS.");
	}
	if (baseUrl.username || baseUrl.password || baseUrl.search || baseUrl.hash) {
		throw new Error("--url must contain only an HTTPS origin and optional path.");
	}
	options.baseUrl = baseUrl.origin;
	return options;
}

export async function verifyOAuthHostingAttempt({
	baseUrl,
	fetchImpl = fetch,
}) {
	const base = new URL(baseUrl);
	const startUrl = new URL("/oauth/start", base);
	startUrl.search = new URLSearchParams({
		clientOrigin: base.origin,
		clientTransactionId: createTransactionId(),
		completionChallenge: createCompletionChallenge(),
		flowVersion: "2",
		mode: "signin",
		provider: "github",
		redirect: "popup",
	}).toString();

	const startResponse = await fetchImpl(startUrl, {
		cache: "no-store",
		headers: {"Cache-Control": "no-cache"},
		redirect: "manual",
		signal: AbortSignal.timeout(10_000),
	});
	if (startResponse.status !== 302) {
		throw new Error(`OAuth start returned HTTP ${startResponse.status}.`);
	}

	const authorizationLocation = startResponse.headers.get("location");
	if (!authorizationLocation) {
		throw new Error("OAuth start did not provide an authorization redirect.");
	}
	const authorizationUrl = new URL(authorizationLocation);
	if (
		authorizationUrl.origin !== "https://github.com" ||
		authorizationUrl.pathname !== "/login/oauth/authorize"
	) {
		throw new Error("OAuth start did not stop at the expected GitHub redirect.");
	}
	const state = authorizationUrl.searchParams.get("state");
	if (!state) throw new Error("GitHub authorization redirect is missing state.");
	if (authorizationUrl.searchParams.has("code")) {
		throw new Error("OAuth smoke verification must never receive a code.");
	}

	const setCookie = startResponse.headers.get("set-cookie");
	if (!setCookie) throw new Error("OAuth start did not set a browser cookie.");
	const browserCookie = setCookie.split(";", 1)[0];
	if (!/^__session=[A-Za-z0-9_-]{43}$/.test(browserCookie)) {
		throw new Error("OAuth start did not set the Firebase Hosting session cookie.");
	}
	for (const requiredAttribute of [
		"Max-Age=300",
		"Path=/",
		"Secure",
		"HttpOnly",
		"SameSite=Lax",
	]) {
		if (!setCookie.includes(requiredAttribute)) {
			throw new Error(`OAuth cookie is missing ${requiredAttribute}.`);
		}
	}
	if (/\bDomain=/i.test(setCookie)) {
		throw new Error("OAuth cookie must remain host-only.");
	}

	const callbackUrl = new URL("/oauth/callback", base);
	callbackUrl.searchParams.set("state", state);
	const callbackResponse = await fetchImpl(callbackUrl, {
		cache: "no-store",
		headers: {
			"Cache-Control": "no-cache",
			Cookie: browserCookie,
		},
		redirect: "manual",
		signal: AbortSignal.timeout(10_000),
	});
	const callbackBody = await callbackResponse.text();
	if (callbackResponse.status !== 400) {
		throw new Error(`OAuth callback returned HTTP ${callbackResponse.status}.`);
	}
	if (!/^text\/html\b/i.test(callbackResponse.headers.get("content-type") ?? "")) {
		throw new Error("OAuth callback did not return the browser-bound HTML response.");
	}
	if (
		!callbackBody.includes("Missing authorization code") ||
		callbackBody.includes("OAuth authentication failed")
	) {
		throw new Error("OAuth callback did not recover its browser-bound state.");
	}

	return {
		callbackStatus: callbackResponse.status,
		provider: "github",
	};
}

export async function verifyOAuthHosting({
	attempts,
	baseUrl,
	delayMillis,
	fetchImpl = fetch,
}) {
	let lastError;
	for (let attempt = 1; attempt <= attempts; attempt += 1) {
		try {
			return {
				...(await verifyOAuthHostingAttempt({baseUrl, fetchImpl})),
				attempt,
			};
		} catch (error) {
			lastError = error;
			if (attempt < attempts) await wait(delayMillis);
		}
	}
	throw lastError;
}

if (process.argv[1] && path.resolve(process.argv[1]) === runnerPath) {
	try {
		const result = await verifyOAuthHosting(
			parseOAuthHostingArguments(process.argv.slice(2)),
		);
		console.log(
			`OAuth Hosting browser binding verified for ${result.provider} on attempt ${result.attempt}.`,
		);
	} catch (error) {
		console.error(`OAuth Hosting verification failed: ${error.message}`);
		process.exitCode = 1;
	}
}
