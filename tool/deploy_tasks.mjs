#!/usr/bin/env node

import path from "node:path";
import {fileURLToPath} from "node:url";
import {resolveBuildTask} from "./build_tasks.mjs";
import {runFirebaseCli} from "./firebase_cli.mjs";
import {runChildProcess} from "./process_runner.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");
const projectId = "better-keep-notes";

const firebaseStep = (args) => ({args, type: "firebase"});
const processStep = (command, args) => ({args, command, type: "process"});

function defineTarget(description, createSteps) {
	return {createSteps, description};
}

const targets = {
	backend: defineTarget("Deploy Functions, Firestore, and Storage.", (extraArgs) => [
		firebaseStep([
			"--",
			"deploy",
			"--config",
			"firebase.deploy.json",
			"--project",
			projectId,
			"--only",
			"functions,firestore:better-keep,storage",
			...extraArgs,
		]),
	]),
	hosting: defineTarget("Build and deploy the marketing site and web application.", (extraArgs) => [
		...resolveBuildTask(["web"]).operations.map((operation) => ({
			...operation,
			type: "process",
		})),
		firebaseStep([
			"--",
			"deploy",
			"--config",
			"firebase.deploy.json",
			"--project",
			projectId,
			"--only",
			"hosting",
			...extraArgs,
		]),
		]),
	"hosting-preview": defineTarget(
		"Build and publish the combined website to the temporary ui-overhaul Hosting channel.",
		(extraArgs) => [
			...resolveBuildTask(["web"]).operations.map((operation) => ({
				...operation,
				type: "process",
			})),
			firebaseStep([
				"--",
				"hosting:channel:deploy",
				"ui-overhaul",
				"--expires",
				"7d",
				"--no-authorized-domains",
				"--config",
				"firebase.deploy.json",
				"--project",
				projectId,
				...extraArgs,
			]),
		],
	),
	indexnow: defineTarget("Submit built public URLs to IndexNow.", (extraArgs) => [
		processStep("node", ["scripts/submit_indexnow.mjs", ...extraArgs]),
	]),
};

export const DEPLOY_TARGET_NAMES = Object.freeze(Object.keys(targets).sort());

export function parseDeployTaskArguments(argv) {
	if (argv.length === 0 || argv[0] === "help" || argv[0] === "--help") {
		return {help: true};
	}
	const [target, ...extraArgs] = argv;
	if (!targets[target]) {
		throw new Error(`Unknown deployment target: ${target}`);
	}
	return {extraArgs, help: false, target};
}

export function resolveDeployTask(argv) {
	const parsed = parseDeployTaskArguments(argv);
	if (parsed.help) {
		return parsed;
	}
	return {
		description: targets[parsed.target].description,
		help: false,
		operations: targets[parsed.target].createSteps(parsed.extraArgs),
		target: parsed.target,
	};
}

export function formatDeployTaskHelp() {
	return [
		"Usage: npm run deploy <target> [arguments]",
		"",
		...DEPLOY_TARGET_NAMES.map(
			(name) => `${name.padEnd(10)} ${targets[name].description}`,
		),
	].join("\n");
}

async function executeOperation(
	operation,
	{processEnv, root, runFirebase, runProcess},
) {
	if (operation.type === "firebase") {
		return runFirebase(operation.args, {processEnv, root});
	}
	return runProcess({
		args: operation.args,
		command: operation.command,
		cwd: root,
		env: processEnv,
	});
}

export async function executeDeployTask(
	task,
	{
		processEnv = process.env,
		root = repositoryRoot,
		runFirebase = runFirebaseCli,
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
				runFirebase,
				runProcess,
			});
		} catch (error) {
			stderr.write(`Unable to deploy ${task.target}: ${error.message}\n`);
			return 1;
		}
		if (exitCode !== 0) {
			return exitCode;
		}
	}
	return 0;
}

export async function runDeployTask(
	argv,
	{
		stdout = process.stdout,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	let task;
	try {
		task = resolveDeployTask(argv);
	} catch (error) {
		stderr.write(`${error.message}\n\n${formatDeployTaskHelp()}\n`);
		return 2;
	}
	if (task.help) {
		stdout.write(`${formatDeployTaskHelp()}\n`);
		return 0;
	}
	return executeDeployTask(task, {stderr, ...executionOptions});
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runDeployTask(process.argv.slice(2));
}
