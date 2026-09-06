#!/usr/bin/env node

import path from "node:path";
import {fileURLToPath} from "node:url";
import {resolveFunctionsTask} from "./functions_tasks.mjs";
import {runFunctionsCommand} from "./functions_runtime.mjs";
import {runChildProcess} from "./process_runner.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");

const processStep = (command, args) => ({
	args,
	command,
	type: "process",
});

function defineAction(description, createSteps) {
	return {createSteps, description};
}

const actions = {
	analyze: defineAction("Analyze Flutter sources.", () => [
		processStep("flutter", ["analyze"]),
	]),
	"apple-config": defineAction(
		"Verify the production Apple Firebase configuration.",
		() => [
			processStep("node", [
				"tool/firebase_apple_config_policy.mjs",
				"--env",
				".env",
				"--macos-plist",
				"macos/Runner/GoogleService-Info.plist",
				"--macos-xcconfig",
				"macos/Runner/Configs/AppInfo.xcconfig",
			]),
		],
	),
	audit: defineAction("Validate and audit project dependencies.", () => [
		processStep("npm", [
			"ls",
			"--all",
			"--workspaces",
			"--include-workspace-root",
		]),
		processStep("npm", ["audit", "--omit=dev"]),
		...resolveFunctionsTask(["audit"]).operations,
	]),
	commit: defineAction("Check components affected by staged changes.", () => [
		processStep("node", ["tool/commit_checks.mjs"]),
	]),
	site: defineAction("Type-check the Astro marketing site.", () => [
		processStep("npm", ["--prefix", "site", "run", "check"]),
	]),
};

export const CHECK_ACTION_NAMES = Object.freeze(Object.keys(actions).sort());

export function parseCheckTaskArguments(argv) {
	if (argv.length === 0) {
		return {help: true};
	}
	if (argv[0] === "help" || argv[0] === "--help") {
		if (argv.length > 1) {
			throw new Error("Check help does not accept extra arguments.");
		}
		return {help: true};
	}
	const [action, ...extraArgs] = argv;
	if (!actions[action]) {
		throw new Error(`Unknown check action: ${action}`);
	}
	if (extraArgs.length > 0) {
		throw new Error(
			`The ${action} check does not accept extra arguments: ${extraArgs.join(" ")}`,
		);
	}
	return {action, help: false};
}

export function resolveCheckTask(argv) {
	const parsed = parseCheckTaskArguments(argv);
	if (parsed.help) {
		return parsed;
	}
	return {
		action: parsed.action,
		description: actions[parsed.action].description,
		help: false,
		operations: actions[parsed.action].createSteps(),
	};
}

export function formatCheckTaskHelp() {
	return [
		"Usage: npm run check <action>",
		"",
		...CHECK_ACTION_NAMES.map(
			(name) => `${name.padEnd(14)} ${actions[name].description}`,
		),
	].join("\n");
}

async function executeOperation(
	operation,
	{processEnv, root, runFunctions, runProcess},
) {
	if (operation.type === "functions") {
		return runFunctions(operation.args, {env: processEnv, root});
	}
	return runProcess({
		args: operation.args,
		command: operation.command,
		cwd: root,
		env: processEnv,
	});
}

export async function executeCheckTask(
	task,
	{
		processEnv = process.env,
		root = repositoryRoot,
		runFunctions = runFunctionsCommand,
		runProcess = runChildProcess,
		stderr = process.stderr,
	} = {},
) {
	for (const operation of task.operations) {
		let exitCode;
		try {
			exitCode = await executeOperation(operation, {
				processEnv,
				root,
				runFunctions,
				runProcess,
			});
		} catch (error) {
			stderr.write(`Unable to run ${task.action} check: ${error.message}\n`);
			return 1;
		}
		if (exitCode !== 0) {
			return exitCode;
		}
	}
	return 0;
}

export async function runCheckTask(
	argv,
	{
		stdout = process.stdout,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	let task;
	try {
		task = resolveCheckTask(argv);
	} catch (error) {
		stderr.write(`${error.message}\n\n${formatCheckTaskHelp()}\n`);
		return 2;
	}
	if (task.help) {
		stdout.write(`${formatCheckTaskHelp()}\n`);
		return 0;
	}
	return executeCheckTask(task, {stderr, ...executionOptions});
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runCheckTask(process.argv.slice(2));
}
