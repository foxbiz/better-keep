import assert from "node:assert/strict";
import test from "node:test";
import {
	BUILD_TARGET_NAMES,
	formatBuildTaskHelp,
	parseBuildTaskArguments,
	resolveBuildTask,
	runBuildTask,
} from "../../tool/build_tasks.mjs";

test("lists build targets and treats an omitted target as help", () => {
	assert.deepEqual(parseBuildTaskArguments([]), {help: true});
	assert.deepEqual(parseBuildTaskArguments(["help"]), {help: true});
	assert.deepEqual(BUILD_TARGET_NAMES, [
		"android",
		"icons",
		"ios",
		"macos",
		"web",
		"windows",
	]);
	assert.match(formatBuildTaskHelp(), /npm run build <target>/);
});

test("maps platform targets to their existing release builds", () => {
	assert.deepEqual(resolveBuildTask(["android"]).operations[0].args, [
		"build",
		"appbundle",
		"--release",
		"--dart-define-from-file=.env",
	]);
	assert.deepEqual(resolveBuildTask(["ios"]).operations[0].args, [
		"build",
		"ios",
		"--release",
		"--dart-define-from-file=.env",
	]);
});

test("forwards build flags after the positional target", () => {
	const web = resolveBuildTask(["web", "--source-maps"]);
	assert.deepEqual(web.operations, [
		{args: ["--source-maps"], command: "./scripts/build_web.sh"},
	]);
	assert.throws(
		() => resolveBuildTask(["icons", "unexpected"]),
		/does not accept extra arguments/,
	);
});

test("web builds the marketing site and Flutter application together", () => {
	assert.deepEqual(resolveBuildTask(["web"]).operations, [
		{args: [], command: "./scripts/build_web.sh"},
	]);
});

test("Windows builds the application before creating the MSIX", () => {
	assert.deepEqual(resolveBuildTask(["windows"]).operations, [
		{
			args: [
				"build",
				"windows",
				"--release",
				"--dart-define-from-file=.env",
			],
			command: "flutter",
		},
		{
			args: ["run", "msix:create", "--build-windows=false"],
			command: "dart",
		},
	]);
});

test("unknown targets fail with help", async () => {
	let stderr = "";
	const exitCode = await runBuildTask(["unknown"], {
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Unknown build target/);
	assert.match(stderr, /Usage: npm run build/);
});

test("build execution stops on the first failure", async () => {
	const calls = [];
	const exitCode = await runBuildTask(["windows"], {
		processEnv: {BASE: "present"},
		runProcess: async (operation) => {
			calls.push(operation);
			return 8;
		},
	});
	assert.equal(exitCode, 8);
	assert.equal(calls.length, 1);
	assert.equal(calls[0].command, "flutter");
	assert.equal(calls[0].env.BASE, "present");
});
