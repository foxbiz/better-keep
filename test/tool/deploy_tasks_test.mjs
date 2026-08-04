import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {
	DEPLOY_TARGET_NAMES,
	formatDeployTaskHelp,
	parseDeployTaskArguments,
	resolveDeployTask,
	runDeployTask,
} from "../../tool/deploy_tasks.mjs";

test("lists deployment targets and treats an omitted target as help", () => {
	assert.deepEqual(parseDeployTaskArguments([]), {help: true});
	assert.deepEqual(parseDeployTaskArguments(["help"]), {help: true});
	assert.deepEqual(DEPLOY_TARGET_NAMES, ["backend", "hosting"]);
	assert.match(formatDeployTaskHelp(), /npm run deploy <target>/);
});

test("preserves the scoped backend deployment", () => {
	assert.deepEqual(resolveDeployTask(["backend"]).operations, [
		{
			args: [
				"--",
				"deploy",
				"--config",
				"firebase.deploy.json",
				"--project",
				"better-keep-notes",
				"--only",
				"functions,firestore:better-keep,storage",
			],
			type: "firebase",
		},
	]);
});

test("builds Flutter web before deploying only Hosting", () => {
	const operations = resolveDeployTask(["hosting", "--debug"]).operations;
	assert.deepEqual(operations[0], {
		args: [
			"build",
			"web",
			"--release",
			"--dart-define-from-file=.env",
		],
		command: "flutter",
		type: "process",
	});
	assert.deepEqual(operations[1], {
		args: [
			"--",
			"deploy",
			"--config",
			"firebase.deploy.json",
			"--project",
			"better-keep-notes",
			"--only",
			"hosting",
			"--debug",
		],
		type: "firebase",
	});
});

test("production Hosting serves the compiled web build with required rewrites", () => {
	const config = JSON.parse(readFileSync("firebase.deploy.json", "utf8"));
	assert.equal(config.hosting.public, "build/web");
	assert.deepEqual(config.hosting.rewrites, [
		{source: "/s/**", destination: "/s/index.html"},
		{source: "**", destination: "/index.html"},
	]);
});

test("unknown deployment targets fail with help", async () => {
	let stderr = "";
	const exitCode = await runDeployTask(["unknown"], {
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Unknown deployment target/);
	assert.match(stderr, /Usage: npm run deploy/);
});

test("Hosting deployment stops when the web build fails", async () => {
	let firebaseCalls = 0;
	const exitCode = await runDeployTask(["hosting"], {
		runFirebase: async () => {
			firebaseCalls += 1;
			return 0;
		},
		runProcess: async () => 9,
	});
	assert.equal(exitCode, 9);
	assert.equal(firebaseCalls, 0);
});

test("backend deployment preserves Firebase exit codes and environment", async () => {
	const calls = [];
	const exitCode = await runDeployTask(["backend"], {
		processEnv: {BASE: "present"},
		runFirebase: async (args, options) => {
			calls.push({args, options});
			return 4;
		},
	});
	assert.equal(exitCode, 4);
	assert.equal(calls[0].options.processEnv.BASE, "present");
});
