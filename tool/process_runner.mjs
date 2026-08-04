import {spawn} from "node:child_process";
import {constants as osConstants} from "node:os";

export function childExitCode(code, signal) {
	if (Number.isInteger(code)) {
		return code;
	}
	if (signal && osConstants.signals[signal]) {
		return 128 + osConstants.signals[signal];
	}
	return 1;
}

function runSpawnedProcess({
	command,
	args,
	cwd,
	env,
	buildResult,
	onChild,
	spawnImplementation = spawn,
	signalHost = process,
	stdio,
}) {
	return new Promise((resolve, reject) => {
		const child = spawnImplementation(command, args, {
			cwd,
			env,
			stdio,
		});
		onChild?.(child);
		const signalHandlers = new Map();
		let settled = false;

		const cleanup = () => {
			for (const [signal, handler] of signalHandlers) {
				signalHost.off?.(signal, handler);
			}
		};
		const settle = (callback) => {
			if (settled) {
				return;
			}
			settled = true;
			cleanup();
			callback();
		};

		for (const signal of ["SIGINT", "SIGTERM"]) {
			const handler = () => {
				if (child.exitCode === null && !child.killed) {
					child.kill(signal);
				}
			};
			signalHandlers.set(signal, handler);
			signalHost.on?.(signal, handler);
		}

		child.once("error", (error) => settle(() => reject(error)));
		child.once("exit", (code, signal) =>
			settle(() => resolve(buildResult(code, signal))),
		);
	});
}

export function runChildProcess({
	command,
	args,
	cwd,
	env,
	spawnImplementation = spawn,
	signalHost = process,
}) {
	return runSpawnedProcess({
		args,
		buildResult: childExitCode,
		command,
		cwd,
		env,
		signalHost,
		spawnImplementation,
		stdio: "inherit",
	});
}

export function runChildProcessWithOutput({
	command,
	args,
	cwd,
	env,
	spawnImplementation = spawn,
	signalHost = process,
}) {
	let stdout = "";
	let stderr = "";
	return runSpawnedProcess({
		args,
		buildResult: (code, signal) => ({
			exitCode: childExitCode(code, signal),
			stderr,
			stdout,
		}),
		command,
		cwd,
		env,
		onChild: (child) => {
			child.stdout?.on("data", (chunk) => {
				stdout += String(chunk);
			});
			child.stderr?.on("data", (chunk) => {
				stderr += String(chunk);
			});
		},
		signalHost,
		spawnImplementation,
		stdio: ["inherit", "pipe", "pipe"],
	});
}
