import assert from "node:assert/strict";
import test from "node:test";
import {
	CHECK_ACTION_NAMES,
	formatCheckTaskHelp,
	parseCheckTaskArguments,
	resolveCheckTask,
	runCheckTask,
} from "../../tool/check_tasks.mjs";

test("lists checks and treats an omitted action as help", () => {
	assert.deepEqual(parseCheckTaskArguments([]), {help: true});
	assert.deepEqual(parseCheckTaskArguments(["help"]), {help: true});
	assert.deepEqual(parseCheckTaskArguments(["--help"]), {help: true});
	assert.deepEqual(CHECK_ACTION_NAMES, ["analyze", "apple-config", "audit", "site"]);
	assert.match(formatCheckTaskHelp(), /npm run check <action>/);
});

test("site check uses the isolated Astro workspace", () => {
	assert.deepEqual(resolveCheckTask(["site"]).operations, [
		{
			args: ["--prefix", "site", "run", "check"],
			command: "npm",
			type: "process",
		},
	]);
});

test("resolves analysis and the production Apple configuration check", () => {
	assert.deepEqual(resolveCheckTask(["analyze"]).operations, [
		{args: ["analyze"], command: "flutter", type: "process"},
	]);
	assert.deepEqual(resolveCheckTask(["apple-config"]).operations, [
		{
			args: [
				"tool/firebase_apple_config_policy.mjs",
				"--env",
				".env",
				"--macos-plist",
				"macos/Runner/GoogleService-Info.plist",
				"--macos-xcconfig",
				"macos/Runner/Configs/AppInfo.xcconfig",
			],
			command: "node",
			type: "process",
		},
	]);
});

test("validates the workspace tree before production audits", () => {
	assert.deepEqual(resolveCheckTask(["audit"]).operations, [
		{
			args: [
				"ls",
				"--all",
				"--workspaces",
				"--include-workspace-root",
			],
			command: "npm",
			type: "process",
		},
		{args: ["audit", "--omit=dev"], command: "npm", type: "process"},
		{
			args: [
				"--",
				"npm",
				"--prefix",
				"functions",
				"audit",
				"--omit=dev",
			],
			type: "functions",
		},
	]);
});

test("unknown actions and unexpected arguments fail with help", async () => {
	assert.throws(
		() => resolveCheckTask(["analyze", "unexpected"]),
		/does not accept extra arguments/,
	);
	assert.throws(
		() => resolveCheckTask(["help", "unexpected"]),
		/help does not accept extra arguments/,
	);
	let stderr = "";
	const exitCode = await runCheckTask(["missing"], {
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Unknown check action: missing/);
	assert.match(stderr, /Usage: npm run check/);
});

test("audit execution preserves environment and stops on the first failure", async () => {
	const processCalls = [];
	const functionsCalls = [];
	const exitCode = await runCheckTask(["audit"], {
		processEnv: {BASE: "present"},
		root: "/repository",
		runFunctions: async (...args) => {
			functionsCalls.push(args);
			return 0;
		},
		runProcess: async (operation) => {
			processCalls.push(operation);
			return 6;
		},
	});
	assert.equal(exitCode, 6);
	assert.equal(processCalls.length, 1);
	assert.equal(processCalls[0].cwd, "/repository");
	assert.equal(processCalls[0].env.BASE, "present");
	assert.equal(functionsCalls.length, 0);
});

test("Functions audit runs after successful tree and root checks", async () => {
	const calls = [];
	const exitCode = await runCheckTask(["audit"], {
		processEnv: {BASE: "present"},
		root: "/repository",
		runFunctions: async (args, options) => {
			calls.push({args, options, type: "functions"});
			return 0;
		},
		runProcess: async (operation) => {
			calls.push({...operation, type: "process"});
			return 0;
		},
	});
	assert.equal(exitCode, 0);
	assert.deepEqual(
		calls.map((call) => call.type),
		["process", "process", "functions"],
	);
	assert.equal(calls[2].options.root, "/repository");
	assert.equal(calls[2].options.env.BASE, "present");
});
