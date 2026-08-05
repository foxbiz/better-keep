#!/usr/bin/env node

import path from "node:path";
import {createInterface} from "node:readline/promises";
import {fileURLToPath} from "node:url";
import {
	runChildProcess,
	runChildProcessWithOutput,
} from "./process_runner.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");

const platforms = {
	android: {
		description: "Run the Android application in debug mode.",
		mobileTarget: "android",
	},
	ios: {
		description: "Run the iOS application in debug mode.",
		mobileTarget: "ios",
	},
	macos: {
		description: "Run the macOS application in debug mode.",
		device: "macos",
	},
	web: {
		description: "Run the web server in debug mode on port 63630.",
		device: "web-server",
		toolArgs: ["--web-port=63630"],
	},
	windows: {
		description: "Run the Windows application in debug mode.",
		device: "windows",
	},
};

export const DEV_PLATFORM_NAMES = Object.freeze(Object.keys(platforms).sort());

function extractDeviceSelector(arguments_) {
	const deviceIds = [];
	const forwardedArgs = [];
	for (let index = 0; index < arguments_.length; index += 1) {
		const argument = arguments_[index];
		if (argument === "-d" || argument === "--device-id") {
			const deviceId = arguments_[index + 1];
			if (!deviceId || deviceId.startsWith("-")) {
				throw new Error(`${argument} requires a device ID.`);
			}
			deviceIds.push(deviceId);
			index += 1;
		} else if (argument.startsWith("--device-id=")) {
			const deviceId = argument.slice("--device-id=".length);
			if (!deviceId) {
				throw new Error("--device-id requires a device ID.");
			}
			deviceIds.push(deviceId);
		} else {
			forwardedArgs.push(argument);
		}
	}
	if (deviceIds.length > 1) {
		throw new Error("Only one Flutter device selector may be provided.");
	}
	return {deviceId: deviceIds[0] ?? null, forwardedArgs};
}

export function parseExplicitDeviceId(arguments_) {
	return extractDeviceSelector(arguments_).deviceId;
}

export function parseDevTaskArguments(argv) {
	if (argv.length === 0 || argv[0] === "help" || argv[0] === "--help") {
		return {help: true};
	}
	const [platform, ...arguments_] = argv;
	const definition = platforms[platform];
	if (!definition) {
		throw new Error(`Unknown development platform: ${platform}`);
	}
	const {deviceId: explicitDeviceId, forwardedArgs: extraArgs} =
		extractDeviceSelector(arguments_);
	if (explicitDeviceId && !definition.mobileTarget) {
		throw new Error(
			`The ${platform} development target uses the fixed Flutter device ID ${definition.device}.`,
		);
	}
	return {explicitDeviceId, extraArgs, help: false, platform};
}

export function createDevOperation(task, deviceId) {
	return {
		args: [
			"run",
			"-d",
			deviceId,
			...task.toolArgs,
			"--dart-define-from-file=.env",
			...task.extraArgs,
		],
		command: "flutter",
	};
}

export function resolveDevTask(argv) {
	const parsed = parseDevTaskArguments(argv);
	if (parsed.help) {
		return parsed;
	}
	const definition = platforms[parsed.platform];
	const deviceId = parsed.explicitDeviceId ?? definition.device ?? null;
	const task = {
		description: definition.description,
		deviceId,
		explicitDeviceId: parsed.explicitDeviceId,
		extraArgs: parsed.extraArgs,
		help: false,
		mobileTarget: definition.mobileTarget ?? null,
		platform: parsed.platform,
		toolArgs: definition.toolArgs ?? [],
	};
	return {
		...task,
		operation: deviceId ? createDevOperation(task, deviceId) : null,
	};
}

export function parseFlutterDevices(source) {
	let devices;
	try {
		devices = JSON.parse(source);
	} catch (error) {
		throw new Error(`Unable to parse Flutter device discovery output: ${error.message}`);
	}
	if (!Array.isArray(devices)) {
		throw new Error("Flutter device discovery output must be a JSON array.");
	}
	return devices.map((device, index) => {
		if (
			!device ||
			typeof device.name !== "string" ||
			typeof device.id !== "string" ||
			typeof device.isSupported !== "boolean" ||
			typeof device.targetPlatform !== "string"
		) {
			throw new Error(`Flutter device entry ${index + 1} is malformed.`);
		}
		return {
			emulator: device.emulator === true,
			id: device.id,
			isSupported: device.isSupported,
			name: device.name,
			sdk: typeof device.sdk === "string" ? device.sdk : "unknown SDK",
			targetPlatform: device.targetPlatform,
		};
	});
}

export function matchingMobileDevices(devices, platform) {
	return devices.filter((device) => {
		if (!device.isSupported) {
			return false;
		}
		return platform === "android"
			? device.targetPlatform === "android" ||
					device.targetPlatform.startsWith("android-")
			: device.targetPlatform === "ios" ||
					device.targetPlatform.startsWith("ios-");
	});
}

export function formatFlutterDevice(device, index) {
	const number = Number.isInteger(index) ? `${index + 1}. ` : "- ";
	const kind = device.emulator ? "emulator" : "physical";
	return `${number}${device.name} [${device.id}] — ${device.sdk}, ${kind}`;
}

export async function chooseMobileDevice(
	platform,
	devices,
	{
		createPrompt = ({input, output}) => createInterface({input, output}),
		input = process.stdin,
		output = process.stdout,
	} = {},
) {
	output.write(
		`Multiple supported ${platform} devices found:\n${devices
			.map((device, index) => formatFlutterDevice(device, index))
			.join("\n")}\n`,
	);
	const prompt = createPrompt({input, output});
	let interrupted = false;
	const interrupt = () => {
		interrupted = true;
		prompt.close();
	};
	prompt.once?.("SIGINT", interrupt);
	try {
		while (true) {
			let answer;
			try {
				answer = await prompt.question(
					`Select a device [1-${devices.length}] or q to cancel: `,
				);
			} catch (error) {
				if (interrupted) {
					return null;
				}
				throw error;
			}
			const normalized = answer.trim().toLowerCase();
			if (normalized === "q" || normalized === "quit") {
				return null;
			}
			const selectedIndex = Number.parseInt(normalized, 10) - 1;
			if (/^\d+$/.test(normalized) && devices[selectedIndex]) {
				return devices[selectedIndex];
			}
			output.write(`Enter a number from 1 to ${devices.length}, or q to cancel.\n`);
		}
	} finally {
		prompt.off?.("SIGINT", interrupt);
		prompt.close();
	}
}

function formatDetectedDevices(devices) {
	if (devices.length === 0) {
		return "No devices were detected by Flutter.";
	}
	return `Detected devices:\n${devices.map((device) => formatFlutterDevice(device)).join("\n")}`;
}

async function discoverMobileDevice(
	task,
	{
		input,
		processEnv,
		root,
		runProcessWithOutput,
		stderr,
		stdout,
		chooseDevice,
	},
) {
	const discovery = await runProcessWithOutput({
		args: ["devices", "--machine"],
		command: "flutter",
		cwd: root,
		env: processEnv,
	});
	if (discovery.exitCode !== 0) {
		stderr.write(
			discovery.stderr ||
				`Flutter device discovery failed with exit code ${discovery.exitCode}.\n`,
		);
		return {exitCode: discovery.exitCode};
	}
	const devices = parseFlutterDevices(discovery.stdout);
	const matches = matchingMobileDevices(devices, task.mobileTarget);
	if (matches.length === 0) {
		stderr.write(
			`No supported ${task.mobileTarget} devices found.\n${formatDetectedDevices(devices)}\n`,
		);
		return {exitCode: 1};
	}
	if (matches.length === 1) {
		return {deviceId: matches[0].id};
	}
	if (!input.isTTY) {
		stderr.write(
			`Multiple supported ${task.mobileTarget} devices found, but this terminal cannot prompt:\n${matches
				.map((device) => formatFlutterDevice(device))
				.join("\n")}\nChoose one with: npm run dev ${task.platform} -- -d <device-id>\n`,
		);
		return {exitCode: 1};
	}
	const selected = await chooseDevice(task.mobileTarget, matches, {
		input,
		output: stdout,
	});
	return selected ? {deviceId: selected.id} : {exitCode: 130};
}

export function formatDevTaskHelp() {
	return [
		"Usage: npm run dev <platform> [arguments]",
		"",
		...DEV_PLATFORM_NAMES.map(
			(name) => `${name.padEnd(10)} ${platforms[name].description}`,
		),
		"",
		"Android and iOS devices are selected automatically.",
		"Override with: npm run dev android -- -d <device-id>",
	].join("\n");
}

export async function executeDevTask(
	task,
	{
		chooseDevice = chooseMobileDevice,
		input = process.stdin,
		processEnv = process.env,
		root = repositoryRoot,
		runProcess = runChildProcess,
		runProcessWithOutput = runChildProcessWithOutput,
		stderr = process.stderr,
		stdout = process.stdout,
	} = {},
) {
	try {
		let operation = task.operation;
		if (!operation) {
			const resolution = await discoverMobileDevice(task, {
				chooseDevice,
				input,
				processEnv,
				root,
				runProcessWithOutput,
				stderr,
				stdout,
			});
			if (resolution.exitCode !== undefined) {
				return resolution.exitCode;
			}
			operation = createDevOperation(task, resolution.deviceId);
		}
		return await runProcess({
			...operation,
			cwd: root,
			env: processEnv,
		});
	} catch (error) {
		stderr.write(`Unable to run ${task.platform} development: ${error.message}\n`);
		return 1;
	}
}

export async function runDevTask(
	argv,
	{
		stdout = process.stdout,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	let task;
	try {
		task = resolveDevTask(argv);
	} catch (error) {
		stderr.write(`${error.message}\n\n${formatDevTaskHelp()}\n`);
		return 2;
	}
	if (task.help) {
		stdout.write(`${formatDevTaskHelp()}\n`);
		return 0;
	}
	return executeDevTask(task, {stderr, stdout, ...executionOptions});
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runDevTask(process.argv.slice(2));
}
