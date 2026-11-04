import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {EventEmitter, once} from "node:events";
import {mkdtemp, rm, writeFile} from "node:fs/promises";
import {createServer} from "node:net";
import {tmpdir} from "node:os";
import {delimiter, join} from "node:path";
import {createInterface} from "node:readline";
import test from "node:test";
import {
	actionableProcessStartError,
	runChildProcessWithOutput,
} from "../../tool/process_runner.mjs";

test("isolated child gets one terminal interrupt and releases its port", {
	skip: process.platform === "win32",
	timeout: 10000,
}, async (context) => {
	const childSource = `
		const server = require('node:net').createServer();
		let signals = 0;
		process.on('SIGINT', () => {
			signals++;
			if (signals === 1) setTimeout(() => server.close(() => {
				console.log(JSON.stringify({signals}));
				process.exit(0);
			}), 200);
		});
		server.listen(0, '127.0.0.1', () => console.log(JSON.stringify({
			pid: process.pid, port: server.address().port
		})));
	`;
	const runnerUrl = new URL("../../tool/process_runner.mjs", import.meta.url)
		.href;
	const wrapper = spawn(
		process.execPath,
		[
			"--input-type=module",
			"-e",
			`
		import {runChildProcess} from ${JSON.stringify(runnerUrl)};
		process.exitCode = await runChildProcess({
			command: process.execPath,
			args: ['-e', ${JSON.stringify(childSource)}],
			detached: true,
		});
	`,
		],
		{detached: true, stdio: ["ignore", "pipe", "pipe"]},
	);
	let childPid;
	const lines = createInterface({input: wrapper.stdout});
	context.after(() => {
		lines.close();
		for (const pid of [childPid, wrapper.pid]) {
			if (!pid) continue;
			try {
				process.kill(pid, "SIGKILL");
			} catch (error) {
				if (error.code !== "ESRCH") throw error;
			}
		}
	});
	const exited = once(wrapper, "exit");
	const iterator = lines[Symbol.asyncIterator]();
	const ready = JSON.parse((await iterator.next()).value);
	childPid = ready.pid;
	// Equivalent to Ctrl+C: signal the foreground wrapper's whole process group.
	process.kill(-wrapper.pid, "SIGINT");
	assert.deepEqual(JSON.parse((await iterator.next()).value), {signals: 1});
	assert.deepEqual(await exited, [0, null]);
	childPid = undefined;
	const probe = createServer();
	await new Promise((resolve, reject) => {
		probe.once("error", reject);
		probe.listen(ready.port, "127.0.0.1", resolve);
	});
	await new Promise((resolve) => probe.close(resolve));
});

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

test("missing commands report actionable terminal and Path guidance", async () => {
	const originalError = Object.assign(new Error("spawn flutter ENOENT"), {
		code: "ENOENT",
	});
	const actionableError = actionableProcessStartError("flutter", originalError);
	assert.equal(actionableError.code, "ENOENT");
	assert.equal(actionableError.cause, originalError);
	assert.match(actionableError.message, /flutter --version/);
	assert.match(actionableError.message, /PATH \(Path on Windows\)/);

	const unchangedError = new Error("permission denied");
	assert.equal(actionableProcessStartError("flutter", unchangedError), unchangedError);

	const child = createChild();
	const resultPromise = runChildProcessWithOutput({
		args: ["build", "windows"],
		command: "flutter",
		cwd: ".",
		env: {},
		spawnImplementation: () => {
			queueMicrotask(() => child.emit("error", originalError));
			return child;
		},
	});
	await assert.rejects(resultPromise, /flutter --version/);
});

test(
	"real Windows adapter launches command shims without corrupting arguments",
	{skip: process.platform !== "win32"},
	async (context) => {
		const fixtureDirectory = await mkdtemp(
			join(tmpdir(), "better-keep-command-shim-"),
		);
		context.after(() => rm(fixtureDirectory, {force: true, recursive: true}));
		await writeFile(
			join(fixtureDirectory, "capture.cjs"),
			"process.stdout.write(JSON.stringify(process.argv.slice(2)));\n",
		);
		await writeFile(
			join(fixtureDirectory, "better-keep-command.cmd"),
			'@echo off\r\nnode "%~dp0capture.cjs" %*\r\n',
		);

		const pathKey =
			Object.keys(process.env).find((name) => name.toLowerCase() === "path") ??
			"Path";
		const environment = {...process.env};
		environment[pathKey] = `${fixtureDirectory}${delimiter}${environment[pathKey] ?? ""}`;
		const arguments_ = ["value with spaces & symbols", "plain"];
		const result = await runChildProcessWithOutput({
			args: arguments_,
			command: "better-keep-command",
			cwd: fixtureDirectory,
			env: environment,
		});

		assert.equal(result.exitCode, 0);
		assert.equal(result.stderr, "");
		assert.deepEqual(JSON.parse(result.stdout), arguments_);
	},
);
