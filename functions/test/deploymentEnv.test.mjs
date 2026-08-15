import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
	readFunctionsDeploymentEnvironment,
	validateFunctionsDeploymentEnvironment,
} from "../scripts/validateDeploymentEnv.mjs";

async function environmentDirectory(contents) {
	const directory = await mkdtemp(
		path.join(os.tmpdir(), "better-keep-functions-env-"),
	);
	await writeFile(path.join(directory, ".env"), contents);
	return directory;
}

test("accepts configured Functions deployment settings", async (t) => {
	const directory = await environmentDirectory(
		"ADMIN_ACCOUNT_UID=configured-admin\n" +
			"GOOGLE_PLAY_REPORT_BUCKET=gs://pubsite_prod_configured\n",
	);
	t.after(() => rm(directory, { recursive: true, force: true }));

	const environment = readFunctionsDeploymentEnvironment({
		cwd: directory,
		processEnv: {},
	});

	assert.doesNotThrow(() =>
		validateFunctionsDeploymentEnvironment(environment),
	);
});

test("accepts required settings from the process environment", async (t) => {
	const directory = await mkdtemp(
		path.join(os.tmpdir(), "better-keep-functions-env-"),
	);
	t.after(() => rm(directory, { recursive: true, force: true }));

	const environment = readFunctionsDeploymentEnvironment({
		cwd: directory,
		processEnv: {
			ADMIN_ACCOUNT_UID: "configured-admin",
			GOOGLE_PLAY_REPORT_BUCKET: "gs://pubsite_prod_configured",
		},
	});

	assert.doesNotThrow(() =>
		validateFunctionsDeploymentEnvironment(environment),
	);
});

test("rejects missing Functions deployment settings without exposing values", async (t) => {
	const directory = await environmentDirectory(
		"GOOGLE_PLAY_REPORT_BUCKET=gs://value-that-must-not-leak\n",
	);
	t.after(() => rm(directory, { recursive: true, force: true }));

	const environment = readFunctionsDeploymentEnvironment({
		cwd: directory,
		processEnv: {},
	});

	assert.throws(
		() => validateFunctionsDeploymentEnvironment(environment),
		(error) => {
			assert.match(error.message, /ADMIN_ACCOUNT_UID/);
			assert.doesNotMatch(error.message, /value-that-must-not-leak/);
			return true;
		},
	);
});

test("rejects empty Functions deployment settings without exposing values", async (t) => {
	const directory = await environmentDirectory(
		"ADMIN_ACCOUNT_UID=\nGOOGLE_PLAY_REPORT_BUCKET=\nUNRELATED=private-value\n",
	);
	t.after(() => rm(directory, { recursive: true, force: true }));

	const environment = readFunctionsDeploymentEnvironment({
		cwd: directory,
		processEnv: {},
	});

	assert.throws(
		() => validateFunctionsDeploymentEnvironment(environment),
		(error) => {
			assert.match(error.message, /ADMIN_ACCOUNT_UID/);
			assert.match(error.message, /GOOGLE_PLAY_REPORT_BUCKET/);
			assert.doesNotMatch(error.message, /private-value/);
			return true;
		},
	);
});
