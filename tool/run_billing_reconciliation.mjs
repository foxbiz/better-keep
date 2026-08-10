#!/usr/bin/env node

import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { runChildProcess } from "./process_runner.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const toolDirectory = path.dirname(runnerPath);
const repositoryRoot = path.resolve(toolDirectory, "..");
const functionsDirectory = path.join(repositoryRoot, "functions");
const requireFromFunctions = createRequire(
	path.join(functionsDirectory, "package.json"),
);
const EXPECTED_PROJECT = "better-keep-notes";
const EXPECTED_DATABASE = "better-keep";
const PROVIDER_SECRETS = Object.freeze({
	all: ["GOOGLE_PLAY_CREDENTIALS", "RAZORPAY_KEY_ID", "RAZORPAY_KEY_SECRET"],
	play: ["GOOGLE_PLAY_CREDENTIALS"],
	razorpay: ["RAZORPAY_KEY_ID", "RAZORPAY_KEY_SECRET"],
});

function argument(argv, name) {
	const prefix = `--${name}=`;
	return argv.find((value) => value.startsWith(prefix))?.slice(prefix.length);
}

export function validateBillingReconciliationArguments(argv) {
	const project = argument(argv, "project");
	const database = argument(argv, "database");
	if (project && project !== EXPECTED_PROJECT) {
		throw new Error(`--project must be ${EXPECTED_PROJECT}`);
	}
	if (database && database !== EXPECTED_DATABASE) {
		throw new Error(`--database must be ${EXPECTED_DATABASE}`);
	}
	const provider = argument(argv, "provider") ?? "all";
	if (!Object.hasOwn(PROVIDER_SECRETS, provider)) {
		throw new Error("--provider must be all, play, or razorpay");
	}
	return [...argv];
}

export function billingReconciliationNodeArguments(argv) {
	return [
		"--env-file-if-exists=.env",
		"--import",
		"tsx",
		"scripts/reconcileBillingData.ts",
		...argv,
	];
}

export function createAdcSecretAccessor({ googleApis } = {}) {
	const { google } = googleApis ?? requireFromFunctions("googleapis");
	const auth = new google.auth.GoogleAuth({
		scopes: ["https://www.googleapis.com/auth/cloud-platform"],
	});
	const secretManager = google.secretmanager({ version: "v1", auth });
	return async (name) => {
		const response = await secretManager.projects.secrets.versions.access({
			name: `projects/${EXPECTED_PROJECT}/secrets/${name}/versions/latest`,
		});
		const encoded = response.data.payload?.data;
		const value =
			typeof encoded === "string"
				? Buffer.from(encoded, "base64").toString("utf8")
				: encoded
					? Buffer.from(encoded).toString("utf8")
					: "";
		if (!value) throw new Error("Secret Manager returned an empty value");
		return value;
	};
}

export async function runBillingReconciliation(
	argv,
	{
		processEnv = process.env,
		processExecPath = process.execPath,
		readSecret = createAdcSecretAccessor(),
		runProcess = runChildProcess,
		root = repositoryRoot,
	} = {},
) {
	const forwardedArguments = validateBillingReconciliationArguments(argv);
	const provider = argument(forwardedArguments, "provider") ?? "all";
	const childEnvironment = {
		...processEnv,
		GCLOUD_PROJECT: EXPECTED_PROJECT,
		GOOGLE_CLOUD_PROJECT: EXPECTED_PROJECT,
		GOOGLE_CLOUD_QUOTA_PROJECT: EXPECTED_PROJECT,
	};
	for (const secretName of PROVIDER_SECRETS[provider]) {
		if (childEnvironment[secretName]) continue;
		try {
			childEnvironment[secretName] = await readSecret(secretName);
		} catch {
			throw new Error(
				`Unable to access Secret Manager value for ${secretName}. ` +
					"Run `gcloud auth application-default login` and verify secret-access permission.",
			);
		}
	}
	return runProcess({
		command: processExecPath,
		args: billingReconciliationNodeArguments(forwardedArguments),
		cwd: path.join(root, "functions"),
		env: childEnvironment,
	});
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	try {
		process.exitCode = await runBillingReconciliation(process.argv.slice(2));
	} catch (error) {
		process.stderr.write(
			`${error instanceof Error ? error.message : String(error)}\n`,
		);
		process.exitCode = 1;
	}
}
