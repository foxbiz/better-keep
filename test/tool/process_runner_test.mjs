import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import test from "node:test";
import {runChildProcessWithOutput} from "../../tool/process_runner.mjs";

function createChild() {
	const child = new EventEmitter();
	child.stdout = new EventEmitter();
	child.stderr = new EventEmitter();
	child.exitCode = null;
	child.killed = false;
	child.kill = (signal) => {
		child.killed = true;
		child.receivedSignal = signal;
	};
	return child;
}

test("captured processes preserve output, options, and exit codes", async () => {
	const child = createChild();
	let spawnCall;
	const resultPromise = runChildProcessWithOutput({
		args: ["devices", "--machine"],
		command: "flutter",
		cwd: "/repository",
		env: {BASE: "present"},
		spawnImplementation: (command, args, options) => {
			spawnCall = {args, command, options};
			queueMicrotask(() => {
				child.stdout.emit("data", Buffer.from("device "));
				child.stdout.emit("data", "list");
				child.stderr.emit("data", "warning");
				child.exitCode = 9;
				child.emit("exit", 9, null);
			});
			return child;
		},
	});

	assert.deepEqual(await resultPromise, {
		exitCode: 9,
		stderr: "warning",
		stdout: "device list",
	});
	assert.deepEqual(spawnCall, {
		args: ["devices", "--machine"],
		command: "flutter",
		options: {
			cwd: "/repository",
			env: {BASE: "present"},
			stdio: ["inherit", "pipe", "pipe"],
		},
	});
});

test("captured processes forward signals and remove host listeners", async () => {
	const child = createChild();
	const signalHost = new EventEmitter();
	const resultPromise = runChildProcessWithOutput({
		args: [],
		command: "flutter",
		cwd: ".",
		env: {},
		signalHost,
		spawnImplementation: () => child,
	});

	signalHost.emit("SIGTERM");
	child.emit("exit", null, "SIGTERM");
	assert.deepEqual(await resultPromise, {
		exitCode: 143,
		stderr: "",
		stdout: "",
	});
	assert.equal(child.receivedSignal, "SIGTERM");
	assert.equal(signalHost.listenerCount("SIGINT"), 0);
	assert.equal(signalHost.listenerCount("SIGTERM"), 0);
});
