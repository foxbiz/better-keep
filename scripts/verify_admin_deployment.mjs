#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");

export function adminScriptSource(html) {
	const matches = [
		...html.matchAll(/<script\b[^>]*\bsrc=["']([^"']+\.js)["'][^>]*>/gi),
	];
	const adminScript = matches.find((match) => /AdminDashboard/i.test(match[1]));
	if (!adminScript)
		throw new Error("Admin HTML does not reference its dashboard script.");
	return adminScript[1];
}

export function compareAdminDeployment(localHtml, remoteHtml) {
	const localScript = adminScriptSource(localHtml);
	const remoteScript = adminScriptSource(remoteHtml);
	if (localScript !== remoteScript) {
		throw new Error(
			`Admin deployment asset mismatch: expected ${path.basename(localScript)}, received ${path.basename(remoteScript)}.`,
		);
	}
	if (!remoteHtml.includes("data-monthly-gross")) {
		throw new Error(
			"Admin deployment is missing the current revenue breakdown markup.",
		);
	}
	if (remoteHtml.includes("data-monthly-revenue")) {
		throw new Error(
			"Admin deployment still contains the legacy revenue markup.",
		);
	}
	return { localScript, remoteScript };
}

export function parseAdminDeploymentArguments(argv) {
	const options = {
		attempts: 10,
		delayMillis: 2000,
		local: "build/admin/index.html",
		url: "https://admin.betterkeep.app/",
	};
	for (let index = 0; index < argv.length; index += 2) {
		const key = argv[index];
		const value = argv[index + 1];
		if (!value) throw new Error(`${key} requires a value.`);
		if (key === "--attempts") options.attempts = Number(value);
		else if (key === "--delay-ms") options.delayMillis = Number(value);
		else if (key === "--local") options.local = value;
		else if (key === "--url") options.url = value;
		else
			throw new Error(`Unknown admin deployment verification option: ${key}`);
	}
	if (!Number.isInteger(options.attempts) || options.attempts < 1) {
		throw new Error("--attempts must be a positive integer.");
	}
	if (!Number.isInteger(options.delayMillis) || options.delayMillis < 0) {
		throw new Error("--delay-ms must be a non-negative integer.");
	}
	return options;
}

function wait(delayMillis) {
	return new Promise((resolve) => setTimeout(resolve, delayMillis));
}

export async function verifyAdminDeployment({
	attempts,
	delayMillis,
	fetchImpl = fetch,
	local,
	url,
}) {
	const localHtml = await readFile(path.resolve(repositoryRoot, local), "utf8");
	let lastError;
	for (let attempt = 1; attempt <= attempts; attempt += 1) {
		try {
			const requestUrl = new URL(url);
			requestUrl.searchParams.set(
				"deployment_check",
				`${Date.now()}-${attempt}`,
			);
			const response = await fetchImpl(requestUrl, {
				cache: "no-store",
				headers: { "Cache-Control": "no-cache" },
				signal: AbortSignal.timeout(10_000),
			});
			if (!response.ok)
				throw new Error(`Admin Hosting returned HTTP ${response.status}.`);
			const comparison = compareAdminDeployment(
				localHtml,
				await response.text(),
			);
			return { ...comparison, attempt };
		} catch (error) {
			lastError = error;
			if (attempt < attempts) await wait(delayMillis);
		}
	}
	throw lastError;
}

if (process.argv[1] && path.resolve(process.argv[1]) === runnerPath) {
	try {
		const result = await verifyAdminDeployment(
			parseAdminDeploymentArguments(process.argv.slice(2)),
		);
		console.log(
			`Admin deployment verified with ${path.basename(result.remoteScript)} on attempt ${result.attempt}.`,
		);
	} catch (error) {
		console.error(`Admin deployment verification failed: ${error.message}`);
		process.exitCode = 1;
	}
}
