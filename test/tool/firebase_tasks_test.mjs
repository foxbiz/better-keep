import assert from "node:assert/strict";
import test from "node:test";
import {
	FIREBASE_ACTION_NAMES,
	formatFirebaseTaskHelp,
	parseFirebaseTaskArguments,
	resolveFirebaseTask,
	runFirebaseTask,
} from "../../tool/firebase_tasks.mjs";

test("lists Firebase actions and treats an omitted action as help", () => {
	assert.deepEqual(parseFirebaseTaskArguments([]), {help: true});
	assert.deepEqual(parseFirebaseTaskArguments(["help"]), {help: true});
	assert.deepEqual(FIREBASE_ACTION_NAMES, [
		"emulator-runtime-check",
		"emulators",
		"indexes",
		"login",
		"runtime-check",
	]);
	assert.match(formatFirebaseTaskHelp(), /npm run firebase <action>/);
});

test("maps runtime checks and administration commands to the pinned CLI", () => {
	assert.deepEqual(resolveFirebaseTask(["runtime-check"]).operations, [
		{args: ["--check-only"], environment: {}, type: "firebase"},
	]);
	assert.deepEqual(
		resolveFirebaseTask(["emulator-runtime-check"]).operations[0].args,
		["--check-only", "--require-java"],
	);
	assert.deepEqual(resolveFirebaseTask(["login", "--no-localhost"]).operations[0].args, [
		"--",
		"login",
		"--no-localhost",
	]);
});

test("emulators check runtimes and build Functions before starting", () => {
	const operations = resolveFirebaseTask(["emulators", "--import=state"]).operations;
	assert.equal(operations.length, 3);
	assert.deepEqual(operations[0].args, ["--check-only", "--require-java"]);
	assert.equal(operations[1].type, "functions");
	assert.deepEqual(operations[1].args.slice(-2), ["run", "build"]);
	assert.equal(operations[2].type, "firebase");
	assert.equal(operations[2].args.at(-1), "--import=state");
	assert.deepEqual(operations[2].environment, {
		OAUTH_LEGACY_V1_ENABLED: "true",
		OAUTH_STATE_SECRET: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	});
});

test("runtime checks reject arguments and unknown actions show help", async () => {
	assert.throws(
		() => resolveFirebaseTask(["runtime-check", "unexpected"]),
		/does not accept extra arguments/,
	);
	let stderr = "";
	const exitCode = await runFirebaseTask(["unknown"], {
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Unknown Firebase action/);
	assert.match(stderr, /Usage: npm run firebase/);
});

test("Firebase execution is fail-fast and merges emulator environments", async () => {
	const firebaseCalls = [];
	const functionsCalls = [];
	const exitCode = await runFirebaseTask(["emulators"], {
		processEnv: {BASE: "present"},
		runFirebase: async (args, options) => {
			firebaseCalls.push({args, options});
			return 0;
		},
		runFunctions: async (args, options) => {
			functionsCalls.push({args, options});
			return 0;
		},
	});
	assert.equal(exitCode, 0);
	assert.equal(firebaseCalls.length, 2);
	assert.equal(functionsCalls.length, 1);
	assert.equal(firebaseCalls[1].options.processEnv.BASE, "present");
	assert.equal(
		firebaseCalls[1].options.processEnv.OAUTH_LEGACY_V1_ENABLED,
		"true",
	);
});

test("Firebase execution stops before later operations after failure", async () => {
	let functionsCalls = 0;
	const exitCode = await runFirebaseTask(["emulators"], {
		runFirebase: async () => 5,
		runFunctions: async () => {
			functionsCalls += 1;
			return 0;
		},
	});
	assert.equal(exitCode, 5);
	assert.equal(functionsCalls, 0);
});
