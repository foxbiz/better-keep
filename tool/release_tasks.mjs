#!/usr/bin/env node

import path from "node:path";
import {fileURLToPath} from "node:url";
import {runCheckTask} from "./check_tasks.mjs";
import {runTestTask} from "./test_tasks.mjs";

const runnerPath = fileURLToPath(import.meta.url);

export const RELEASE_STAGES = Object.freeze([
	Object.freeze({args: ["audit"], type: "check"}),
	Object.freeze({args: ["analyze"], type: "check"}),
	Object.freeze({args: ["release"], type: "test"}),
]);

export function parseReleaseTaskArguments(argv) {
	if (argv.length === 0) {
		return {help: false};
	}
	if (argv.length === 1 && (argv[0] === "help" || argv[0] === "--help")) {
		return {help: true};
	}
	throw new Error(`Release does not accept arguments: ${argv.join(" ")}`);
}

export function resolveReleaseTask(argv) {
	const parsed = parseReleaseTaskArguments(argv);
	return parsed.help
		? parsed
		: {help: false, stages: RELEASE_STAGES.map((stage) => ({...stage}))};
}

export function formatReleaseTaskHelp() {
	return [
		"Usage: npm run release",
		"",
		"Runs the release gate in this order:",
		"1. npm run check audit",
		"2. npm run check analyze",
		"3. npm test release",
	].join("\n");
}

export async function executeReleaseTask(
	task,
	{
		runCheck = runCheckTask,
		runTests = runTestTask,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	for (const stage of task.stages) {
		const runner = stage.type === "check" ? runCheck : runTests;
		let exitCode;
		try {
			exitCode = await runner(stage.args, {stderr, ...executionOptions});
		} catch (error) {
			stderr.write(`Unable to run release gate: ${error.message}\n`);
			return 1;
		}
		if (exitCode !== 0) {
			return exitCode;
		}
	}
	return 0;
}

export async function runReleaseTask(
	argv,
	{
		stdout = process.stdout,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	let task;
	try {
		task = resolveReleaseTask(argv);
	} catch (error) {
		stderr.write(`${error.message}\n\n${formatReleaseTaskHelp()}\n`);
		return 2;
	}
	if (task.help) {
		stdout.write(`${formatReleaseTaskHelp()}\n`);
		return 0;
	}
	return executeReleaseTask(task, {stderr, ...executionOptions});
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runReleaseTask(process.argv.slice(2));
}
