import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import path from "node:path";
import test from "node:test";
import {
	parseRunnerArguments,
	runFirebaseCli,
} from "../../tool/firebase_cli.mjs";
import {
	buildRuntimeEnvironment,
	resolvePinnedJavaRuntime,
	resolvePinnedNodeRuntime,
} from "../../tool/firebase_runtime_resolver.mjs";
import {
	FIREBASE_HOST_NODE_ENV,
	FIREBASE_JAVA_HOME_ENV,
	FIREBASE_NODE_BIN_ENV,
	FIREBASE_REEXEC_ENV,
	PINNED_JAVA_VERSION,
	PINNED_NODE_VERSION,
	firebaseCommandRequiresJava,
	isPinnedJavaVersion,
	isPinnedNodeVersion,
	normalizeJavaVersion,
	normalizeNodeVersion,
	parseJavaMajor,
	parseNodeMajor,
} from "../../tool/firebase_runtime_policy.mjs";
import {
	parseFunctionsCommand,
	runFunctionsCommand,
} from "../../tool/functions_runtime.mjs";
import {
	childExitCode,
	runChildProcess,
} from "../../tool/process_runner.mjs";

const pinnedNodeOutput = `v${PINNED_NODE_VERSION}`;
const pinnedJavaOutput =
	`openjdk version "${PINNED_JAVA_VERSION}" 2026-04-21 LTS`;

test("parses supported Node and Java versions exactly", () => {
	assert.equal(parseNodeMajor(pinnedNodeOutput), 22);
	assert.equal(normalizeNodeVersion(`${pinnedNodeOutput}+build`), null);
	assert.equal(parseNodeMajor("not-a-version"), null);
	assert.equal(normalizeNodeVersion("v22"), null);
	assert.equal(parseJavaMajor(pinnedJavaOutput), 21);
	assert.equal(normalizeJavaVersion(pinnedJavaOutput), PINNED_JAVA_VERSION);
	assert.equal(parseJavaMajor('java version "1.8.0_442"'), 8);
	assert.equal(parseJavaMajor("openjdk 27-ea 2026-09-15"), 27);
	assert.equal(normalizeJavaVersion("not-a-version"), null);
	assert.equal(isPinnedNodeVersion(pinnedNodeOutput), true);
	assert.equal(isPinnedNodeVersion(`${pinnedNodeOutput}-rc.1`), false);
	assert.equal(isPinnedNodeVersion("v22.13.1"), false);
	assert.equal(isPinnedJavaVersion(pinnedJavaOutput), true);
	assert.equal(isPinnedJavaVersion('openjdk version "21.0.11-ea"'), false);
	assert.equal(isPinnedJavaVersion('openjdk version "21.0.2"'), false);
});

test("Java is selected only for Java-backed emulator commands", () => {
	assert.equal(firebaseCommandRequiresJava(["deploy", "--only", "functions"]), false);
	assert.equal(
		firebaseCommandRequiresJava([
			"emulators:start",
			"--only",
			"auth,functions,hosting",
		]),
		false,
	);
	assert.equal(
		firebaseCommandRequiresJava([
			"emulators:exec",
			"--only=firestore,storage",
			"node --test",
		]),
		true,
	);
	assert.equal(firebaseCommandRequiresJava(["emulators:start"]), true);
	assert.equal(
		firebaseCommandRequiresJava([
			"--project",
			"better-keep-notes",
			"emulators:start",
			"--only=storage",
		]),
		true,
	);
});

test("Node resolution prioritizes an explicit valid override", () => {
	const runtime = resolvePinnedNodeRuntime({
		processVersion: pinnedNodeOutput,
		processExecPath: "/active/node",
		env: {[FIREBASE_NODE_BIN_ENV]: "/custom path/node"},
		probeNode: (candidate) =>
			candidate === "/custom path/node" ? pinnedNodeOutput : "",
	});
	assert.deepEqual(runtime, {
		bin: "/custom path/node",
		source: FIREBASE_NODE_BIN_ENV,
		version: PINNED_NODE_VERSION,
	});
});

test("Node resolution uses the active exact runtime before NVM", () => {
	const runtime = resolvePinnedNodeRuntime({
		processVersion: pinnedNodeOutput,
		processExecPath: "/active/node",
		env: {NVM_DIR: "/nvm"},
		probeNode: () => {
			throw new Error("NVM must not be probed");
		},
	});
	assert.equal(runtime.bin, "/active/node");
	assert.equal(runtime.source, "active process");
});

test("Node resolution discovers the exact NVM companion in paths with spaces", () => {
	const expected = path.join(
		"/runtime storage",
		"versions",
		"node",
		`v${PINNED_NODE_VERSION}`,
		"bin",
		"node",
	);
	const runtime = resolvePinnedNodeRuntime({
		processVersion: "v24.14.0",
		processExecPath: "/host/node",
		env: {NVM_DIR: "/runtime storage"},
		probeNode: (candidate) => (candidate === expected ? pinnedNodeOutput : ""),
	});
	assert.equal(runtime.bin, expected);
	assert.equal(runtime.source, "NVM companion runtime");
});

test("invalid Node overrides fail instead of silently falling through", () => {
	assert.throws(
		() =>
			resolvePinnedNodeRuntime({
				processVersion: pinnedNodeOutput,
				env: {[FIREBASE_NODE_BIN_ENV]: "/wrong/node"},
				probeNode: () => "v22.13.1",
			}),
		(error) => {
			assert.match(error.message, /BETTER_KEEP_FIREBASE_NODE_BIN/);
			assert.match(error.message, /22\.13\.1/);
			assert.doesNotMatch(error.message, /nvm use/);
			return true;
		},
	);
	assert.throws(
		() =>
			resolvePinnedNodeRuntime({
				env: {[FIREBASE_NODE_BIN_ENV]: "relative/node"},
			}),
		/must be an absolute path/,
	);
});

test("missing Node companion fails with installation-only remediation", () => {
	assert.throws(
		() =>
			resolvePinnedNodeRuntime({
				processVersion: "v24.14.0",
				env: {NVM_DIR: "/missing"},
				probeNode: () => "",
			}),
		(error) => {
			assert.match(error.message, /nvm install 22\.23\.1/);
			assert.doesNotMatch(error.message, /nvm use/);
			return true;
		},
	);
});

test("missing Node fails before Firebase can perform deployment work", async () => {
	let childStarted = false;
	let stderr = "";
	const exitCode = await runFirebaseCli(["--", "deploy"], {
		nodeVersion: "v24.14.0",
		resolveNodeRuntime: () => {
			throw new Error("Install: nvm install 22.23.1");
		},
		runChild: async () => {
			childStarted = true;
			return 0;
		},
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 1);
	assert.equal(childStarted, false);
	assert.match(stderr, /nvm install 22\.23\.1/);
});

test("Java resolution follows override, CI, active, and SDKMAN priority", () => {
	const candidates = [
		{
			env: {[FIREBASE_JAVA_HOME_ENV]: "/override"},
			expectedHome: "/override",
			expectedSource: FIREBASE_JAVA_HOME_ENV,
		},
		{
			env: {JAVA_HOME_21_X64: "/ci"},
			expectedHome: "/ci",
			expectedSource: "JAVA_HOME_21_X64",
		},
		{
			env: {JAVA_HOME: "/active"},
			expectedHome: "/active",
			expectedSource: "active JAVA_HOME",
		},
		{
			env: {SDKMAN_CANDIDATES_DIR: "/sdk"},
			expectedHome: path.join("/sdk", "java", "21.0.11-tem"),
			expectedSource: "SDKMAN companion runtime",
		},
	];

	for (const candidate of candidates) {
		const runtime = resolvePinnedJavaRuntime({
			env: candidate.env,
			platform: "linux",
			probeJava: (javaBin) =>
				javaBin === path.join(candidate.expectedHome, "bin", "java")
					? pinnedJavaOutput
					: "",
		});
		assert.equal(runtime.home, candidate.expectedHome);
		assert.equal(runtime.source, candidate.expectedSource);
	}
});

test("invalid Java overrides fail without trying lower-priority candidates", () => {
	assert.throws(
		() =>
			resolvePinnedJavaRuntime({
				env: {
					[FIREBASE_JAVA_HOME_ENV]: "/wrong",
					JAVA_HOME_21_X64: "/valid-but-must-not-be-used",
				},
				platform: "linux",
				probeJava: (javaBin) =>
					javaBin.includes("/wrong/")
						? 'openjdk version "21.0.2"'
						: pinnedJavaOutput,
			}),
		/BETTER_KEEP_FIREBASE_JAVA_HOME/,
	);
	assert.throws(
		() =>
			resolvePinnedJavaRuntime({
				env: {[FIREBASE_JAVA_HOME_ENV]: "relative/jdk"},
			}),
		/must be an absolute path/,
	);
});

test("macOS Java discovery is validated against the exact patch", () => {
	let discoveryCalls = 0;
	const runtime = resolvePinnedJavaRuntime({
		env: {SDKMAN_CANDIDATES_DIR: "/missing"},
		platform: "darwin",
		probeJava: (javaBin) =>
			javaBin === "/Library/Java/Exact/bin/java" ? pinnedJavaOutput : "",
		spawnSyncImplementation: (command) => {
			assert.equal(command, "/usr/libexec/java_home");
			discoveryCalls += 1;
			return {
				error: null,
				status: 0,
				stdout: "/Library/Java/Exact\n",
				stderr: "",
			};
		},
	});
	assert.equal(runtime.source, "macOS java_home");
	assert.equal(discoveryCalls, 1);
});

test("missing Java companion fails with installation-only remediation", () => {
	assert.throws(
		() =>
			resolvePinnedJavaRuntime({
				env: {SDKMAN_CANDIDATES_DIR: "/missing"},
				platform: "linux",
				probeJava: () => "",
			}),
		(error) => {
			assert.match(error.message, /sdk install java 21\.0\.11-tem/);
			assert.doesNotMatch(error.message, /sdk use|sdk env/);
			return true;
		},
	);
});

test("missing Java fails before a Java-backed emulator can start", async () => {
	let childStarted = false;
	let stderr = "";
	const exitCode = await runFirebaseCli(
		["--", "emulators:start", "--only", "storage"],
		{
			nodeVersion: pinnedNodeOutput,
			resolveNodeRuntime: () => ({
				bin: "/firebase/node",
				source: "test",
				version: PINNED_NODE_VERSION,
			}),
			resolveJavaRuntime: () => {
				throw new Error("Install: sdk install java 21.0.11-tem");
			},
			runChild: async () => {
				childStarted = true;
				return 0;
			},
			stderr: {write: (value) => (stderr += value)},
		},
	);
	assert.equal(exitCode, 1);
	assert.equal(childStarted, false);
	assert.match(stderr, /sdk install java 21\.0\.11-tem/);
});

test("runtime environment is child-scoped and prepends both companions", () => {
	const original = {PATH: "/host/bin", JAVA_HOME: "/host/java", KEEP: "yes"};
	const result = buildRuntimeEnvironment({
		env: original,
		nodeRuntime: {bin: "/node path/bin/node"},
		javaRuntime: {home: "/java path"},
		platform: "linux",
	});
	assert.deepEqual(original, {
		PATH: "/host/bin",
		JAVA_HOME: "/host/java",
		KEEP: "yes",
	});
	assert.equal(result.JAVA_HOME, "/java path");
	assert.equal(
		result.PATH,
		"/java path/bin:/node path/bin:/host/bin",
	);
	assert.equal(result.KEEP, "yes");
});

test("runner arguments infer Java requirements and reject ambiguous check mode", () => {
	assert.deepEqual(parseRunnerArguments(["--check-only", "--require-java"]), {
		checkOnly: true,
		firebaseArgs: [],
		requireJava: true,
	});
	assert.deepEqual(
		parseRunnerArguments([
			"--",
			"emulators:exec",
			"--only",
			"firestore,storage",
			"node --test",
		]),
		{
			checkOnly: false,
			firebaseArgs: [
				"emulators:exec",
				"--only",
				"firestore,storage",
				"node --test",
			],
			requireJava: true,
		},
	);
	assert.throws(
		() => parseRunnerArguments(["--check-only", "--", "--version"]),
		/does not accept/,
	);
});

test("Node 24 Firebase invocation transparently re-executes with Node 22", async () => {
	let childOptions;
	const exitCode = await runFirebaseCli(["--check-only"], {
		nodeVersion: "v24.14.0",
		processExecPath: "/host/node",
		processEnv: {PATH: "/host/bin"},
		currentRunnerPath: "/repo path/tool/firebase_cli.mjs",
		resolveNodeRuntime: () => ({
			bin: "/node path/bin/node",
			source: "test",
			version: PINNED_NODE_VERSION,
		}),
		runChild: async (options) => {
			childOptions = options;
			return 23;
		},
	});
	assert.equal(exitCode, 23);
	assert.equal(childOptions.command, "/node path/bin/node");
	assert.deepEqual(childOptions.args, [
		"/repo path/tool/firebase_cli.mjs",
		"--check-only",
	]);
	assert.equal(childOptions.env[FIREBASE_REEXEC_ENV], "1");
	assert.equal(childOptions.env[FIREBASE_HOST_NODE_ENV], "v24.14.0");
	assert.equal(childOptions.env.PATH, "/node path/bin:/host/bin");
});

test("re-execution recursion fails before a Firebase child starts", async () => {
	let childStarted = false;
	let stderr = "";
	const exitCode = await runFirebaseCli(["--check-only"], {
		nodeVersion: "v24.14.0",
		processEnv: {[FIREBASE_REEXEC_ENV]: "1"},
		resolveNodeRuntime: () => ({
			bin: "/node",
			source: "test",
			version: PINNED_NODE_VERSION,
		}),
		runChild: async () => {
			childStarted = true;
			return 0;
		},
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 1);
	assert.equal(childStarted, false);
	assert.match(stderr, /recursion detected/);
});

test("check-only reports host and selected Firebase runtimes", async () => {
	let stdout = "";
	const exitCode = await runFirebaseCli(
		["--check-only", "--require-java"],
		{
			nodeVersion: pinnedNodeOutput,
			processExecPath: "/firebase/node",
			processEnv: {[FIREBASE_HOST_NODE_ENV]: "v24.14.0"},
			resolveNodeRuntime: () => ({
				bin: "/firebase/node",
				source: "active process",
				version: PINNED_NODE_VERSION,
			}),
			resolveJavaRuntime: () => ({
				bin: "/firebase/java/bin/java",
				home: "/firebase/java",
				source: "test companion",
				version: PINNED_JAVA_VERSION,
			}),
			stdout: {write: (value) => (stdout += value)},
		},
	);
	assert.equal(exitCode, 0);
	assert.match(stdout, /Host Node\.js: 24\.14\.0/);
	assert.match(stdout, /Firebase Node\.js: 22\.23\.1/);
	assert.match(stdout, /Firebase Java: 21\.0\.11/);
});

test("non-emulator Firebase commands do not resolve Java", async () => {
	let childOptions;
	const exitCode = await runFirebaseCli(["--", "--version"], {
		nodeVersion: pinnedNodeOutput,
		processExecPath: "/firebase/node",
		processEnv: {PATH: "/host/bin"},
		resolveNodeRuntime: () => ({
			bin: "/firebase/node",
			source: "test",
			version: PINNED_NODE_VERSION,
		}),
		resolveJavaRuntime: () => {
			throw new Error("Java must remain optional");
		},
		runChild: async (options) => {
			childOptions = options;
			return 0;
		},
	});
	assert.equal(exitCode, 0);
	assert.equal(childOptions.command, "/firebase/node");
	assert.equal(childOptions.env.JAVA_HOME, undefined);
	assert.equal(childOptions.env.PATH, "/firebase:/host/bin");
});

test("Functions wrapper selects Node 22 for npm without changing parent env", async () => {
	const env = {PATH: "/host/bin"};
	let childOptions;
	const exitCode = await runFunctionsCommand(
		["--", "npm", "--prefix", "functions", "test"],
		{
			env,
			platform: "linux",
			resolveNodeRuntime: () => ({
				bin: "/node path/bin/node",
				source: "test",
				version: PINNED_NODE_VERSION,
			}),
			runChild: async (options) => {
				childOptions = options;
				return 17;
			},
		},
	);
	assert.equal(exitCode, 17);
	assert.equal(childOptions.command, "/node path/bin/npm");
	assert.deepEqual(childOptions.args, ["--prefix", "functions", "test"]);
	assert.equal(childOptions.env.PATH, "/node path/bin:/host/bin");
	assert.deepEqual(env, {PATH: "/host/bin"});
	assert.deepEqual(parseFunctionsCommand(["--", "node", "--version"]), [
		"node",
		"--version",
	]);
	assert.throws(() => parseFunctionsCommand(["npm", "test"]), /required after/);
});

test("child exit codes and terminating signals are preserved", () => {
	assert.equal(childExitCode(7, null), 7);
	assert.equal(childExitCode(null, "SIGTERM"), 143);
	assert.equal(childExitCode(null, "UNKNOWN"), 1);
});

test("child process exit status and signals are propagated without leaks", async () => {
	const signalHost = new EventEmitter();
	const child = new EventEmitter();
	child.exitCode = null;
	child.killed = false;
	child.kill = (signal) => {
		child.killed = true;
		child.receivedSignal = signal;
	};
	const spawnImplementation = () => {
		queueMicrotask(() => signalHost.emit("SIGTERM"));
		queueMicrotask(() => {
			child.exitCode = 23;
			child.emit("exit", 23, null);
		});
		return child;
	};

	const exitCode = await runChildProcess({
		command: "node",
		args: [],
		cwd: ".",
		env: {},
		spawnImplementation,
		signalHost,
	});
	assert.equal(exitCode, 23);
	assert.equal(child.receivedSignal, "SIGTERM");
	assert.equal(signalHost.listenerCount("SIGINT"), 0);
	assert.equal(signalHost.listenerCount("SIGTERM"), 0);
});
