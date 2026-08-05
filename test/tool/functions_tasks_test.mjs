import assert from "node:assert/strict";
import test from "node:test";
import {
	FUNCTIONS_ACTION_NAMES,
	formatFunctionsTaskHelp,
	parseFunctionsTaskArguments,
	resolveFunctionsTask,
	runFunctionsTask,
} from "../../tool/functions_tasks.mjs";

test("lists Functions actions and treats an omitted action as help", () => {
	assert.deepEqual(parseFunctionsTaskArguments([]), {help: true});
	assert.deepEqual(parseFunctionsTaskArguments(["help"]), {help: true});
	assert.deepEqual(FUNCTIONS_ACTION_NAMES, [
		"audit",
		"build",
		"ci",
		"install",
		"logs",
		"serve",
		"shell",
	]);
	assert.match(formatFunctionsTaskHelp(), /npm run functions <action>/);
});

test("routes npm actions through the pinned Functions runtime", () => {
	assert.deepEqual(resolveFunctionsTask(["build"]).operations, [
		{
			args: ["--", "npm", "--prefix", "functions", "run", "build"],
			type: "functions",
		},
	]);
	assert.deepEqual(resolveFunctionsTask(["audit"]).operations[0].args, [
		"--",
		"npm",
		"--prefix",
		"functions",
		"audit",
		"--omit=dev",
	]);
});

test("serve and shell build before invoking the pinned Firebase CLI", () => {
	for (const action of ["serve", "shell"]) {
		const operations = resolveFunctionsTask([action]).operations;
		assert.equal(operations.length, 2);
		assert.equal(operations[0].type, "functions");
		assert.equal(operations[1].type, "firebase");
		assert.deepEqual(operations[0].args.slice(-2), ["run", "build"]);
	}
});

test("forwards positional and prefixed arguments to the selected action", () => {
	assert.deepEqual(
		resolveFunctionsTask(["build", "--watch"]).operations[0].args,
		[
			"--",
			"npm",
			"--prefix",
			"functions",
			"run",
			"build",
			"--",
			"--watch",
		],
	);
	assert.deepEqual(
		resolveFunctionsTask(["logs", "--only", "cleanup"]).operations[0].args.slice(
			-2,
		),
		["--only", "cleanup"],
	);
});

test("unknown actions fail with help", async () => {
	let stderr = "";
	const exitCode = await runFunctionsTask(["unknown"], {
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Unknown Functions action/);
	assert.match(stderr, /Usage: npm run functions/);
});

test("Functions execution is fail-fast and preserves the parent environment", async () => {
	const functionsCalls = [];
	const firebaseCalls = [];
	const exitCode = await runFunctionsTask(["serve"], {
		processEnv: {BASE: "present"},
		runFirebase: async (...args) => {
			firebaseCalls.push(args);
			return 0;
		},
		runFunctions: async (...args) => {
			functionsCalls.push(args);
			return 6;
		},
	});
	assert.equal(exitCode, 6);
	assert.equal(functionsCalls.length, 1);
	assert.equal(firebaseCalls.length, 0);
	assert.equal(functionsCalls[0][1].env.BASE, "present");
});
