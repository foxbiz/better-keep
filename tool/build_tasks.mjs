#!/usr/bin/env node

import path from "node:path";
import {fileURLToPath} from "node:url";
import {runChildProcess} from "./process_runner.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");

const processStep = (command, args) => ({args, command});

function defineTarget(description, createSteps, {acceptsArguments = true} = {}) {
	return {acceptsArguments, createSteps, description};
}

function flutterBuild(target, extraArgs) {
	return processStep("flutter", [
		"build",
		target,
		"--release",
		"--dart-define-from-file=.env",
		...extraArgs,
	]);
}

function prepareMacosXcode(extraArgs) {
	return processStep("flutter", [
		"build",
		"macos",
		"--config-only",
		"--release",
		"--dart-define-from-file=.env",
		...extraArgs,
	]);
}

const targets = {
	android: defineTarget("Build the release Android App Bundle.", (extraArgs) => [
		flutterBuild("appbundle", extraArgs),
	]),
	icons: defineTarget(
		"Generate the custom icon font.",
		() => [processStep("dart", ["./scripts/generate_custom_icons.dart"])],
		{acceptsArguments: false},
	),
	ios: defineTarget("Build the release iOS application.", (extraArgs) => [
		flutterBuild("ios", extraArgs),
	]),
	macos: defineTarget("Build the release macOS application.", (extraArgs) => [
		flutterBuild("macos", extraArgs),
	]),
	"macos-xcode": defineTarget(
		"Prepare generated macOS configuration for Xcode archiving.",
		(extraArgs) => [
			prepareMacosXcode(extraArgs),
			processStep("node", ["tool/verify_macos_archive_config.mjs"]),
		],
	),
	web: defineTarget("Build the marketing site and release web application.", (extraArgs) => [
		processStep("./scripts/build_web.sh", extraArgs),
	]),
	windows: defineTarget("Build the release Windows MSIX package.", (extraArgs) => [
		flutterBuild("windows", extraArgs),
		processStep("dart", ["run", "msix:create", "--build-windows=false"]),
	]),
};

export const BUILD_TARGET_NAMES = Object.freeze(Object.keys(targets).sort());

export function parseBuildTaskArguments(argv) {
	if (argv.length === 0 || argv[0] === "help" || argv[0] === "--help") {
		return {help: true};
	}
	const [target, ...extraArgs] = argv;
	const definition = targets[target];
	if (!definition) {
		throw new Error(`Unknown build target: ${target}`);
	}
	if (!definition.acceptsArguments && extraArgs.length > 0) {
		throw new Error(
			`The ${target} build target does not accept extra arguments: ${extraArgs.join(" ")}`,
		);
	}
	return {extraArgs, help: false, target};
}

export function resolveBuildTask(argv) {
	const parsed = parseBuildTaskArguments(argv);
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

export function formatBuildTaskHelp() {
	return [
		"Usage: npm run build <target> [arguments]",
		"",
		...BUILD_TARGET_NAMES.map(
			(name) => `${name.padEnd(10)} ${targets[name].description}`,
		),
	].join("\n");
}

export async function executeBuildTask(
	task,
	{
		processEnv = process.env,
		root = repositoryRoot,
		runProcess = runChildProcess,
		stderr = process.stderr,
	} = {},
) {
	for (const operation of task.operations) {
		let exitCode;
		try {
			exitCode = await runProcess({
				...operation,
				cwd: root,
				env: processEnv,
			});
		} catch (error) {
			stderr.write(`Unable to run the ${task.target} build: ${error.message}\n`);
			return 1;
		}
		if (exitCode !== 0) {
			return exitCode;
		}
	}
	return 0;
}

export async function runBuildTask(
	argv,
	{
		stdout = process.stdout,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	let task;
	try {
		task = resolveBuildTask(argv);
	} catch (error) {
		stderr.write(`${error.message}\n\n${formatBuildTaskHelp()}\n`);
		return 2;
	}
	if (task.help) {
		stdout.write(`${formatBuildTaskHelp()}\n`);
		return 0;
	}
	return executeBuildTask(task, {stderr, ...executionOptions});
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runBuildTask(process.argv.slice(2));
}
