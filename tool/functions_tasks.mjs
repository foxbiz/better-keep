#!/usr/bin/env node

import path from "node:path";
import {fileURLToPath} from "node:url";
import {runFirebaseCli} from "./firebase_cli.mjs";
import {runFunctionsCommand} from "./functions_runtime.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");
const projectId = "better-keep-notes";

const firebaseStep = (args) => ({args, type: "firebase"});
const functionsStep = (args) => ({args, type: "functions"});

function defineAction(description, createSteps) {
	return {createSteps, description};
}

function npmFunctionsStep(commandArgs, extraArgs) {
	return functionsStep([
		"--",
		"npm",
		"--prefix",
		"functions",
		...commandArgs,
		...extraArgs,
	]);
}

function npmFunctionsScriptStep(script, extraArgs) {
	return npmFunctionsStep(
		["run", script, ...(extraArgs.length > 0 ? ["--"] : [])],
		extraArgs,
	);
}

const buildOperation = () => npmFunctionsScriptStep("build", []);

const actions = {
	audit: defineAction("Audit Functions production dependencies.", (extraArgs) => [
		npmFunctionsStep(["audit", "--omit=dev"], extraArgs),
	]),
	build: defineAction("Build Cloud Functions.", (extraArgs) => [
		npmFunctionsScriptStep("build", extraArgs),
	]),
	ci: defineAction("Install locked Cloud Functions dependencies.", (extraArgs) => [
		npmFunctionsStep(["ci"], extraArgs),
	]),
	install: defineAction("Install Cloud Functions dependencies.", (extraArgs) => [
		npmFunctionsStep(["install"], extraArgs),
	]),
	logs: defineAction("Read production Functions logs.", (extraArgs) => [
		firebaseStep([
			"--",
			"functions:log",
			"--config",
			"firebase.deploy.json",
			"--project",
			projectId,
			...extraArgs,
		]),
	]),
	serve: defineAction("Build and start the Functions emulator.", (extraArgs) => [
		buildOperation(),
		firebaseStep([
			"--",
			"emulators:start",
			"--only",
			"functions",
			"--config",
			"firebase.emulators.json",
			"--project",
			projectId,
			...extraArgs,
		]),
	]),
	shell: defineAction("Build and open the Functions shell.", (extraArgs) => [
		buildOperation(),
		firebaseStep([
			"--",
			"functions:shell",
			"--config",
			"firebase.emulators.json",
			"--project",
			projectId,
			...extraArgs,
		]),
	]),
};

export const FUNCTIONS_ACTION_NAMES = Object.freeze(Object.keys(actions).sort());

export function parseFunctionsTaskArguments(argv) {
	if (argv.length === 0 || argv[0] === "help" || argv[0] === "--help") {
		return {help: true};
	}
	const [action, ...extraArgs] = argv;
	if (!actions[action]) {
		throw new Error(`Unknown Functions action: ${action}`);
	}
	return {action, extraArgs, help: false};
}

export function resolveFunctionsTask(argv) {
	const parsed = parseFunctionsTaskArguments(argv);
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

export function formatFunctionsTaskHelp() {
	return [
		"Usage: npm run functions <action> [arguments]",
		"",
		...FUNCTIONS_ACTION_NAMES.map(
			(name) => `${name.padEnd(10)} ${actions[name].description}`,
		),
	].join("\n");
}

async function executeOperation(
	operation,
	{processEnv, root, runFirebase, runFunctions},
) {
	if (operation.type === "firebase") {
		return runFirebase(operation.args, {processEnv, root});
	}
	return runFunctions(operation.args, {env: processEnv, root});
}

export async function executeFunctionsTask(
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
			stderr.write(`Unable to run Functions ${task.action}: ${error.message}\n`);
			return 1;
		}
		if (exitCode !== 0) {
			return exitCode;
		}
	}
	return 0;
}

export async function runFunctionsTask(
	argv,
	{
		stdout = process.stdout,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	let task;
	try {
		task = resolveFunctionsTask(argv);
	} catch (error) {
		stderr.write(`${error.message}\n\n${formatFunctionsTaskHelp()}\n`);
		return 2;
	}
	if (task.help) {
		stdout.write(`${formatFunctionsTaskHelp()}\n`);
		return 0;
	}
	return executeFunctionsTask(task, {stderr, ...executionOptions});
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runFunctionsTask(process.argv.slice(2));
}
