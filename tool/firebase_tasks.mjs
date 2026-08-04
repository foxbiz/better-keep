#!/usr/bin/env node

import path from "node:path";
import {fileURLToPath} from "node:url";
import {runFirebaseCli} from "./firebase_cli.mjs";
import {runFunctionsCommand} from "./functions_runtime.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");
const projectId = "better-keep-notes";
const emulatorOAuthEnvironment = {
	OAUTH_LEGACY_V1_ENABLED: "true",
	OAUTH_STATE_SECRET: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
};

const firebaseStep = (args, environment = {}) => ({
	args,
	environment,
	type: "firebase",
});
const functionsStep = (args) => ({args, type: "functions"});

function defineAction(description, createSteps, {acceptsArguments = true} = {}) {
	return {acceptsArguments, createSteps, description};
}

const actions = {
	"emulator-runtime-check": defineAction(
		"Report the pinned Firebase and Java emulator runtimes.",
		() => [firebaseStep(["--check-only", "--require-java"])],
		{acceptsArguments: false},
	),
	emulators: defineAction("Start the complete local Firebase suite.", (extraArgs) => [
		firebaseStep(["--check-only", "--require-java"]),
		functionsStep(["--", "npm", "--prefix", "functions", "run", "build"]),
		firebaseStep(
			[
				"--",
				"emulators:start",
				"--only",
				"auth,firestore,functions,hosting,storage",
				"--config",
				"firebase.emulators.json",
				"--project",
				projectId,
				...extraArgs,
			],
			emulatorOAuthEnvironment,
		),
	]),
	indexes: defineAction("List indexes for the application database.", (extraArgs) => [
		firebaseStep([
			"--",
			"firestore:indexes",
			"--project",
			projectId,
			"--database=better-keep",
			...extraArgs,
		]),
	]),
	login: defineAction("Authenticate the pinned Firebase CLI.", (extraArgs) => [
		firebaseStep(["--", "login", ...extraArgs]),
	]),
	"runtime-check": defineAction(
		"Report the pinned Firebase runtime.",
		() => [firebaseStep(["--check-only"])],
		{acceptsArguments: false},
	),
};

export const FIREBASE_ACTION_NAMES = Object.freeze(Object.keys(actions).sort());

export function parseFirebaseTaskArguments(argv) {
	if (argv.length === 0 || argv[0] === "help" || argv[0] === "--help") {
		return {help: true};
	}
	const [action, ...extraArgs] = argv;
	const definition = actions[action];
	if (!definition) {
		throw new Error(`Unknown Firebase action: ${action}`);
	}
	if (!definition.acceptsArguments && extraArgs.length > 0) {
		throw new Error(
			`The ${action} Firebase action does not accept extra arguments: ${extraArgs.join(" ")}`,
		);
	}
	return {action, extraArgs, help: false};
}

export function resolveFirebaseTask(argv) {
	const parsed = parseFirebaseTaskArguments(argv);
	if (parsed.help) {
		return parsed;
	}
	return {
		action: parsed.action,
		description: actions[parsed.action].description,
		help: false,
		operations: actions[parsed.action].createSteps(parsed.extraArgs),
	};
}

export function formatFirebaseTaskHelp() {
	return [
		"Usage: npm run firebase <action> [arguments]",
		"",
		...FIREBASE_ACTION_NAMES.map(
			(name) => `${name.padEnd(24)} ${actions[name].description}`,
		),
	].join("\n");
}

async function executeOperation(
	operation,
	{processEnv, root, runFirebase, runFunctions},
) {
	if (operation.type === "functions") {
		return runFunctions(operation.args, {env: processEnv, root});
	}
	return runFirebase(operation.args, {
		processEnv: {...processEnv, ...operation.environment},
		root,
	});
}

export async function executeFirebaseTask(
	task,
	{
		processEnv = process.env,
		root = repositoryRoot,
		runFirebase = runFirebaseCli,
		runFunctions = runFunctionsCommand,
		stderr = process.stderr,
	} = {},
) {
	for (const operation of task.operations) {
		let exitCode;
		try {
			exitCode = await executeOperation(operation, {
				processEnv,
				root,
				runFirebase,
				runFunctions,
			});
		} catch (error) {
			stderr.write(`Unable to run Firebase ${task.action}: ${error.message}\n`);
			return 1;
		}
		if (exitCode !== 0) {
			return exitCode;
		}
	}
	return 0;
}

export async function runFirebaseTask(
	argv,
	{
		stdout = process.stdout,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	let task;
	try {
		task = resolveFirebaseTask(argv);
	} catch (error) {
		stderr.write(`${error.message}\n\n${formatFirebaseTaskHelp()}\n`);
		return 2;
	}
	if (task.help) {
		stdout.write(`${formatFirebaseTaskHelp()}\n`);
		return 0;
	}
	return executeFirebaseTask(task, {stderr, ...executionOptions});
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runFirebaseTask(process.argv.slice(2));
}
