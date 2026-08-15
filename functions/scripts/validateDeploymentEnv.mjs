#!/usr/bin/env node

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";

export const REQUIRED_FUNCTIONS_DEPLOYMENT_ENV = Object.freeze([
	"ADMIN_ACCOUNT_UID",
	"GOOGLE_PLAY_REPORT_BUCKET",
]);

export function readFunctionsDeploymentEnvironment({
	cwd = process.cwd(),
	processEnv = process.env,
} = {}) {
	let fileEnvironment = {};
	try {
		fileEnvironment = parseEnv(readFileSync(path.join(cwd, ".env"), "utf8"));
	} catch (error) {
		if (error?.code !== "ENOENT") throw error;
	}
	return { ...fileEnvironment, ...processEnv };
}

export function validateFunctionsDeploymentEnvironment(environment) {
	const missing = REQUIRED_FUNCTIONS_DEPLOYMENT_ENV.filter(
		(key) => typeof environment[key] !== "string" || !environment[key].trim(),
	);
	if (missing.length > 0) {
		throw new Error(
			"Functions deployment environment is missing required non-secret " +
				`configuration: ${missing.join(", ")}`,
		);
	}
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
const scriptPath = fileURLToPath(import.meta.url);
if (invokedPath === scriptPath) {
	try {
		validateFunctionsDeploymentEnvironment(
			readFunctionsDeploymentEnvironment(),
		);
		console.log(
			`Functions deployment environment validation passed (${REQUIRED_FUNCTIONS_DEPLOYMENT_ENV.length} required settings configured).`,
		);
	} catch (error) {
		console.error(error instanceof Error ? error.message : String(error));
		process.exitCode = 1;
	}
}
