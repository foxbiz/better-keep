#!/usr/bin/env node

import path from "node:path";
import {fileURLToPath} from "node:url";
import {
	buildRuntimeEnvironment,
	resolvePinnedNodeRuntime,
} from "./firebase_runtime_resolver.mjs";
import {runChildProcess} from "./process_runner.mjs";

const toolDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(toolDirectory, "..");

export function parseFunctionsCommand(argv) {
	const separator = argv.indexOf("--");
	if (separator === -1 || separator === argv.length - 1) {
		throw new Error(
			"Functions command arguments are required after `--` (for example, `-- npm --prefix functions test`).",
		);
	}
	if (separator !== 0) {
		throw new Error("Unknown Functions runtime wrapper arguments.");
	}
	return argv.slice(1);
}

function resolveCommand(command, nodeRuntime, platform = process.platform) {
	if (command === "node") {
		return nodeRuntime.bin;
	}
	if (command === "npm") {
		return path.join(
			path.dirname(nodeRuntime.bin),
			platform === "win32" ? "npm.cmd" : "npm",
		);
	}
	return command;
}

export async function runFunctionsCommand(
	argv,
	{
		env = process.env,
		platform = process.platform,
		root = repositoryRoot,
		resolveNodeRuntime = resolvePinnedNodeRuntime,
		runChild = runChildProcess,
		stderr = process.stderr,
	} = {},
) {
	let commandArguments;
	try {
		commandArguments = parseFunctionsCommand(argv);
	} catch (error) {
		stderr.write(`${error.message}\n`);
		return 2;
	}

	let nodeRuntime;
	try {
		nodeRuntime = resolveNodeRuntime({env, platform});
	} catch (error) {
		stderr.write(`${error.message}\n`);
		return 1;
	}

	const [command, ...args] = commandArguments;
	try {
		return await runChild({
			command: resolveCommand(command, nodeRuntime, platform),
			args,
			cwd: root,
			env: buildRuntimeEnvironment({env, nodeRuntime, platform}),
		});
	} catch (error) {
		stderr.write(`Unable to start the Functions command: ${error.message}\n`);
		return 1;
	}
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
	process.exitCode = await runFunctionsCommand(process.argv.slice(2));
}
