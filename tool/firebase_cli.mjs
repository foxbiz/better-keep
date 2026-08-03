#!/usr/bin/env node

import {readFileSync} from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {
	buildRuntimeEnvironment,
	resolvePinnedJavaRuntime,
	resolvePinnedNodeRuntime,
} from "./firebase_runtime_resolver.mjs";
import {
	FIREBASE_HOST_NODE_ENV,
	FIREBASE_REEXEC_ENV,
	firebaseCommandRequiresJava,
	formatRuntimeReport,
	isPinnedNodeVersion,
} from "./firebase_runtime_policy.mjs";
import {runChildProcess} from "./process_runner.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const toolDirectory = path.dirname(runnerPath);
const repositoryRoot = path.resolve(toolDirectory, "..");

export function parseRunnerArguments(argv) {
	let checkOnly = false;
	let requireJava = false;
	let index = 0;

	for (; index < argv.length; index += 1) {
		const argument = argv[index];
		if (argument === "--") {
			index += 1;
			break;
		}
		if (argument === "--check-only") {
			checkOnly = true;
			continue;
		}
		if (argument === "--require-java") {
			requireJava = true;
			continue;
		}
		break;
	}

	const firebaseArgs = argv.slice(index);
	if (checkOnly && firebaseArgs.length > 0) {
		throw new Error("--check-only does not accept Firebase CLI arguments.");
	}
	if (!checkOnly && firebaseArgs.length === 0) {
		throw new Error(
			"Firebase CLI arguments are required after `--` (for example, `-- --version`).",
		);
	}

	return {
		checkOnly,
		firebaseArgs,
		requireJava:
			requireJava ||
			(!checkOnly && firebaseCommandRequiresJava(firebaseArgs)),
	};
}

export function resolveFirebaseCliBin(root = repositoryRoot) {
	const manifestPath = path.join(
		root,
		"node_modules",
		"firebase-tools",
		"package.json",
	);
	let manifest;
	try {
		manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
	} catch (error) {
		throw new Error(
			`Unable to load the pinned Firebase CLI. Run \`npm install\` first. (${error.message})`,
		);
	}

	const binPath =
		typeof manifest.bin === "string" ? manifest.bin : manifest.bin?.firebase;
	if (typeof binPath !== "string" || binPath.length === 0) {
		throw new Error("The installed firebase-tools package has no Firebase CLI bin.");
	}
	return path.resolve(path.dirname(manifestPath), binPath);
}

export async function runFirebaseCli(
	argv,
	{
		nodeVersion = process.version,
		processEnv = process.env,
		processExecPath = process.execPath,
		platform = process.platform,
		resolveNodeRuntime = resolvePinnedNodeRuntime,
		resolveJavaRuntime = resolvePinnedJavaRuntime,
		runChild = runChildProcess,
		signalHost = process,
		stderr = process.stderr,
		stdout = process.stdout,
		root = repositoryRoot,
		currentRunnerPath = runnerPath,
	} = {},
) {
	let options;
	try {
		options = parseRunnerArguments(argv);
	} catch (error) {
		stderr.write(`${error.message}\n`);
		return 2;
	}

	let nodeRuntime;
	try {
		nodeRuntime = resolveNodeRuntime({
			env: processEnv,
			platform,
			processVersion: nodeVersion,
			processExecPath,
		});
	} catch (error) {
		stderr.write(`${error.message}\n`);
		return 1;
	}

	if (!isPinnedNodeVersion(nodeVersion)) {
		if (processEnv[FIREBASE_REEXEC_ENV]) {
			stderr.write(
				"Firebase runtime recursion detected before Node.js reached the pinned version.\n",
			);
			return 1;
		}
		const reexecEnvironment = buildRuntimeEnvironment({
			env: {
				...processEnv,
				[FIREBASE_REEXEC_ENV]: "1",
				[FIREBASE_HOST_NODE_ENV]:
					processEnv[FIREBASE_HOST_NODE_ENV] || nodeVersion,
			},
			nodeRuntime,
			platform,
		});
		try {
			return await runChild({
				command: nodeRuntime.bin,
				args: [currentRunnerPath, ...argv],
				cwd: root,
				env: reexecEnvironment,
				signalHost,
			});
		} catch (error) {
			stderr.write(
				`Unable to restart Firebase with Node.js ${nodeRuntime.version}: ${error.message}\n`,
			);
			return 1;
		}
	}

	let javaRuntime;
	if (options.requireJava) {
		try {
			javaRuntime = resolveJavaRuntime({
				env: processEnv,
				platform,
			});
		} catch (error) {
			stderr.write(`${error.message}\n`);
			return 1;
		}
	}

	if (options.checkOnly) {
		stdout.write(
			`${formatRuntimeReport({
				hostNodeVersion: processEnv[FIREBASE_HOST_NODE_ENV] || nodeVersion,
				firebaseNode: nodeRuntime,
				javaRuntime,
				requireJava: options.requireJava,
			})}\n`,
		);
		return 0;
	}

	let firebaseBin;
	try {
		firebaseBin = resolveFirebaseCliBin(root);
	} catch (error) {
		stderr.write(`${error.message}\n`);
		return 1;
	}

	const childEnvironment = buildRuntimeEnvironment({
		env: processEnv,
		nodeRuntime,
		javaRuntime,
		platform,
	});
	try {
		return await runChild({
			command: nodeRuntime.bin,
			args: [firebaseBin, ...options.firebaseArgs],
			cwd: root,
			env: childEnvironment,
			signalHost,
		});
	} catch (error) {
		stderr.write(`Unable to start the pinned Firebase CLI: ${error.message}\n`);
		return 1;
	}
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runFirebaseCli(process.argv.slice(2));
}
