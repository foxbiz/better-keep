import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import test from "node:test";
import {
	DEV_PLATFORM_NAMES,
	chooseMobileDevice,
	formatDevTaskHelp,
	matchingMobileDevices,
	parseDevTaskArguments,
	parseExplicitDeviceId,
	parseFlutterDevices,
	resolveDevTask,
	runDevTask,
} from "../../tool/dev_tasks.mjs";

const androidPhone = {
	emulator: false,
	id: "android-physical",
	isSupported: true,
	name: "Android Phone",
	sdk: "Android 16",
	targetPlatform: "android-arm64",
};
const androidEmulator = {
	emulator: true,
	id: "emulator-5554",
	isSupported: true,
	name: "Android Emulator",
	sdk: "Android 15",
	targetPlatform: "android-x64",
};
const iphone = {
	emulator: false,
	id: "ios-physical",
	isSupported: true,
	name: "iPhone",
	sdk: "iOS 26",
	targetPlatform: "ios",
};
const macos = {
	emulator: false,
	id: "macos",
	isSupported: true,
	name: "macOS",
	sdk: "macOS 26",
	targetPlatform: "darwin",
};

const discoveryResult = (devices, overrides = {}) => ({
	exitCode: 0,
	stderr: "",
	stdout: JSON.stringify(devices),
	...overrides,
});

test("lists development platforms and explains mobile device selection", () => {
	assert.deepEqual(parseDevTaskArguments([]), {help: true});
	assert.deepEqual(parseDevTaskArguments(["help"]), {help: true});
	assert.deepEqual(DEV_PLATFORM_NAMES, [
		"android",
		"ios",
		"macos",
		"web",
		"windows",
	]);
	assert.match(formatDevTaskHelp(), /npm run dev <platform>/);
	assert.match(formatDevTaskHelp(), /selected automatically/);
	assert.match(formatDevTaskHelp(), /-- -d <device-id>/);
});

test("mobile targets defer their Flutter operation until device discovery", () => {
	for (const platform of ["android", "ios"]) {
		const task = resolveDevTask([platform, "--flavor", "development"]);
		assert.equal(task.mobileTarget, platform);
		assert.equal(task.deviceId, null);
		assert.equal(task.operation, null);
		assert.deepEqual(task.extraArgs, ["--flavor", "development"]);
	}
});

test("fixed targets retain exact Flutter device IDs and arguments", () => {
	assert.deepEqual(resolveDevTask(["macos"]).operation, {
		args: ["run", "-d", "macos", "--dart-define-from-file=.env"],
		command: "flutter",
	});
	assert.deepEqual(resolveDevTask(["windows"]).operation.args, [
		"run",
		"-d",
		"windows",
		"--dart-define-from-file=.env",
	]);
	assert.deepEqual(resolveDevTask(["web"]).operation.args, [
		"run",
		"-d",
		"web-server",
		"--web-port=63630",
		"--dart-define-from-file=.env",
	]);
});

test("extracts and normalizes every explicit Flutter device flag", () => {
	for (const arguments_ of [
		["-d", "serial-1"],
		["--device-id", "serial-1"],
		["--device-id=serial-1"],
	]) {
		assert.equal(parseExplicitDeviceId(arguments_), "serial-1");
		const operation = resolveDevTask([
			"android",
			...arguments_,
			"--flavor",
			"development",
		]).operation;
		assert.deepEqual(operation.args, [
			"run",
			"-d",
			"serial-1",
			"--dart-define-from-file=.env",
			"--flavor",
			"development",
		]);
	}
});

test("rejects malformed, repeated, or fixed-target device selectors", () => {
	for (const arguments_ of [["-d"], ["--device-id"], ["--device-id="]]) {
		assert.throws(
			() => resolveDevTask(["android", ...arguments_]),
			/requires a device ID/,
		);
	}
	assert.throws(
		() => resolveDevTask(["android", "-d", "one", "--device-id=two"]),
		/Only one Flutter device selector/,
	);
	assert.throws(
		() => resolveDevTask(["web", "-d", "chrome"]),
		/uses the fixed Flutter device ID web-server/,
	);
});

test("parses and filters supported Flutter mobile devices", () => {
	const unsupportedAndroid = {...androidPhone, id: "old", isSupported: false};
	const devices = parseFlutterDevices(
		JSON.stringify([androidPhone, unsupportedAndroid, iphone, macos]),
	);
	assert.deepEqual(matchingMobileDevices(devices, "android"), [androidPhone]);
	assert.deepEqual(matchingMobileDevices(devices, "ios"), [iphone]);
	assert.throws(() => parseFlutterDevices("not json"), /Unable to parse/);
	assert.throws(() => parseFlutterDevices("{}"), /must be a JSON array/);
	assert.throws(
		() => parseFlutterDevices('[{"name":"incomplete"}]'),
		/entry 1 is malformed/,
	);
});

test("automatically runs the only supported Android device", async () => {
	const discoveryCalls = [];
	const runCalls = [];
	const exitCode = await runDevTask(["android", "--flavor", "development"], {
		processEnv: {BASE: "present"},
		root: "/repository",
		runProcess: async (operation) => {
			runCalls.push(operation);
			return 0;
		},
		runProcessWithOutput: async (operation) => {
			discoveryCalls.push(operation);
			return discoveryResult([androidPhone, iphone, macos]);
		},
	});
	assert.equal(exitCode, 0);
	assert.deepEqual(discoveryCalls, [
		{
			args: ["devices", "--machine"],
			command: "flutter",
			cwd: "/repository",
			env: {BASE: "present"},
		},
	]);
	assert.deepEqual(runCalls[0], {
		args: [
			"run",
			"-d",
			"android-physical",
			"--dart-define-from-file=.env",
			"--flavor",
			"development",
		],
		command: "flutter",
		cwd: "/repository",
		env: {BASE: "present"},
	});
});

test("automatically runs the only supported iOS device", async () => {
	const runCalls = [];
	const exitCode = await runDevTask(["ios"], {
		runProcess: async (operation) => {
			runCalls.push(operation);
			return 0;
		},
		runProcessWithOutput: async () => discoveryResult([androidPhone, iphone]),
	});
	assert.equal(exitCode, 0);
	assert.deepEqual(runCalls[0].args.slice(0, 3), [
		"run",
		"-d",
		"ios-physical",
	]);
});

test("prompts with only matching devices and runs the selected ID", async () => {
	const runCalls = [];
	let promptCall;
	const exitCode = await runDevTask(["android"], {
		chooseDevice: async (...args) => {
			promptCall = args;
			return args[1][1];
		},
		input: {isTTY: true},
		runProcess: async (operation) => {
			runCalls.push(operation);
			return 0;
		},
		runProcessWithOutput: async () =>
			discoveryResult([androidPhone, iphone, androidEmulator]),
	});
	assert.equal(exitCode, 0);
	assert.equal(promptCall[0], "android");
	assert.deepEqual(promptCall[1], [androidPhone, androidEmulator]);
	assert.deepEqual(runCalls[0].args.slice(0, 3), [
		"run",
		"-d",
		"emulator-5554",
	]);
});

test("numbered prompt repeats invalid input and supports cancellation", async () => {
	const answers = ["invalid", "3", "2"];
	let output = "";
	let closed = false;
	const selected = await chooseMobileDevice("android", [androidPhone, androidEmulator], {
		createPrompt: () => ({
			close: () => (closed = true),
			off: () => {},
			once: () => {},
			question: async () => answers.shift(),
		}),
		input: {isTTY: true},
		output: {write: (value) => (output += value)},
	});
	assert.equal(selected.id, "emulator-5554");
	assert.equal(closed, true);
	assert.match(output, /Android Phone \[android-physical\]/);
	assert.match(output, /Enter a number from 1 to 2/);

	const cancelled = await chooseMobileDevice("android", [androidPhone, androidEmulator], {
		createPrompt: () => ({
			close: () => {},
			off: () => {},
			once: () => {},
			question: async () => "q",
		}),
		input: {isTTY: true},
		output: {write: () => {}},
	});
	assert.equal(cancelled, null);
});

test("interrupting the numbered prompt cancels without selecting a device", async () => {
	const prompt = new EventEmitter();
	let rejectQuestion;
	prompt.question = () =>
		new Promise((resolve, reject) => {
			rejectQuestion = reject;
			queueMicrotask(() => prompt.emit("SIGINT"));
		});
	prompt.close = () => rejectQuestion?.(new Error("prompt closed"));
	const selected = await chooseMobileDevice("ios", [iphone, {...iphone, id: "two"}], {
		createPrompt: () => prompt,
		input: {isTTY: true},
		output: {write: () => {}},
	});
	assert.equal(selected, null);
});

test("multiple devices fail safely when the terminal cannot prompt", async () => {
	let stderr = "";
	let launched = false;
	const exitCode = await runDevTask(["android"], {
		input: {isTTY: false},
		runProcess: async () => {
			launched = true;
			return 0;
		},
		runProcessWithOutput: async () =>
			discoveryResult([androidPhone, androidEmulator, iphone]),
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 1);
	assert.equal(launched, false);
	assert.match(stderr, /Multiple supported android devices/);
	assert.match(stderr, /android-physical/);
	assert.match(stderr, /emulator-5554/);
	assert.doesNotMatch(stderr, /ios-physical/);
	assert.match(stderr, /npm run dev android -- -d <device-id>/);
});

test("zero matching devices reports every detected device without launching", async () => {
	let stderr = "";
	let launched = false;
	const exitCode = await runDevTask(["android"], {
		runProcess: async () => {
			launched = true;
			return 0;
		},
		runProcessWithOutput: async () => discoveryResult([iphone, macos]),
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 1);
	assert.equal(launched, false);
	assert.match(stderr, /No supported android devices found/);
	assert.match(stderr, /iPhone \[ios-physical\]/);
	assert.match(stderr, /macOS \[macos\]/);
});

test("discovery failures and malformed output stop before Flutter run", async () => {
	let launched = false;
	let stderr = "";
	const failureCode = await runDevTask(["android"], {
		runProcess: async () => {
			launched = true;
			return 0;
		},
		runProcessWithOutput: async () => ({
			exitCode: 7,
			stderr: "discovery failed\n",
			stdout: "",
		}),
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(failureCode, 7);
	assert.equal(launched, false);
	assert.equal(stderr, "discovery failed\n");

	stderr = "";
	const malformedCode = await runDevTask(["ios"], {
		runProcessWithOutput: async () => discoveryResult([], {stdout: "invalid"}),
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(malformedCode, 1);
	assert.match(stderr, /Unable to parse Flutter device discovery output/);
});

test("explicit mobile IDs bypass discovery and preserve Flutter exit codes", async () => {
	const calls = [];
	const exitCode = await runDevTask(["android", "-d", "serial-1"], {
		processEnv: {BASE: "present"},
		runProcess: async (operation) => {
			calls.push(operation);
			return 8;
		},
		runProcessWithOutput: async () => {
			throw new Error("explicit IDs must bypass discovery");
		},
	});
	assert.equal(exitCode, 8);
	assert.equal(calls.length, 1);
	assert.equal(calls[0].env.BASE, "present");
	assert.deepEqual(calls[0].args.slice(0, 3), ["run", "-d", "serial-1"]);
});

test("unknown platforms fail with help", async () => {
	let stderr = "";
	const exitCode = await runDevTask(["linux"], {
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Unknown development platform/);
	assert.match(stderr, /Usage: npm run dev/);
});
