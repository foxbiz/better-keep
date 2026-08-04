import assert from "node:assert/strict";
import test from "node:test";
import {
	RELEASE_STAGES,
	formatReleaseTaskHelp,
	parseReleaseTaskArguments,
	resolveReleaseTask,
	runReleaseTask,
} from "../../tool/release_tasks.mjs";

test("plain release runs the gate while help only describes it", async () => {
	assert.deepEqual(parseReleaseTaskArguments([]), {help: false});
	assert.deepEqual(parseReleaseTaskArguments(["help"]), {help: true});
	assert.deepEqual(parseReleaseTaskArguments(["--help"]), {help: true});
	assert.match(formatReleaseTaskHelp(), /npm run check audit/);
	assert.match(formatReleaseTaskHelp(), /npm test release/);

	let stdout = "";
	assert.equal(
		await runReleaseTask(["help"], {
			stdout: {write: (value) => (stdout += value)},
		}),
		0,
	);
	assert.match(stdout, /Runs the release gate in this order/);
});

test("release resolves the established fail-fast sequence", () => {
	assert.deepEqual(RELEASE_STAGES, [
		{args: ["audit"], type: "check"},
		{args: ["analyze"], type: "check"},
		{args: ["release"], type: "test"},
	]);
	assert.deepEqual(resolveReleaseTask([]).stages, RELEASE_STAGES);
});

test("release rejects unsupported arguments with help", async () => {
	assert.throws(
		() => resolveReleaseTask(["unexpected"]),
		/does not accept arguments/,
	);
	let stderr = "";
	const exitCode = await runReleaseTask(["unexpected"], {
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Release does not accept arguments/);
	assert.match(stderr, /Usage: npm run release/);
});

test("release delegates to check and test runners in order", async () => {
	const calls = [];
	const options = {processEnv: {BASE: "present"}, root: "/repository"};
	const exitCode = await runReleaseTask([], {
		...options,
		runCheck: async (args, receivedOptions) => {
			calls.push({args, options: receivedOptions, type: "check"});
			return 0;
		},
		runTests: async (args, receivedOptions) => {
			calls.push({args, options: receivedOptions, type: "test"});
			return 0;
		},
	});
	assert.equal(exitCode, 0);
	assert.deepEqual(
		calls.map(({args, type}) => ({args, type})),
		RELEASE_STAGES,
	);
	assert.equal(calls[0].options.processEnv.BASE, "present");
	assert.equal(calls[2].options.root, "/repository");
});

test("release stops before tests when analysis fails", async () => {
	const calls = [];
	const exitCode = await runReleaseTask([], {
		runCheck: async (args) => {
			calls.push(args[0]);
			return args[0] === "analyze" ? 7 : 0;
		},
		runTests: async () => {
			calls.push("tests");
			return 0;
		},
	});
	assert.equal(exitCode, 7);
	assert.deepEqual(calls, ["audit", "analyze"]);
});
