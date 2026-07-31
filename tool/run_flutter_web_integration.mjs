import {spawn} from "node:child_process";
import {createServer} from "node:net";
import {dirname, join} from "node:path";
import {fileURLToPath} from "node:url";

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const flutterBinary =
	process.env.FLUTTER_BINARY ??
	(process.platform === "win32" ? "flutter.bat" : "flutter");
const chromeDriverBinary =
	process.env.CHROMEDRIVER_BINARY ??
	(process.platform === "win32" ? "chromedriver.exe" : "chromedriver");
const timeoutMilliseconds = Number.parseInt(
	process.env.FLUTTER_WEB_INTEGRATION_TIMEOUT_MS ?? "240000",
	10,
);

function reserveLoopbackPort() {
	return new Promise((resolve, reject) => {
		const server = createServer();
		server.unref();
		server.once("error", reject);
		server.listen(0, "127.0.0.1", () => {
			const address = server.address();
			const port =
				typeof address === "object" && address !== null
					? address.port
					: undefined;
			server.close((error) => {
				if (error) {
					reject(error);
				} else if (port === undefined) {
					reject(new Error("Failed to allocate a ChromeDriver port."));
				} else {
					resolve(port);
				}
			});
		});
	});
}

function captureProcessOutput(child, prefix) {
	const output = [];
	const capture = (stream, destination) => {
		stream?.on("data", (chunk) => {
			const value = chunk.toString();
			output.push(value);
			if (output.length > 200) output.shift();
			destination.write(value);
		});
	};
	capture(child.stdout, process.stdout);
	capture(child.stderr, process.stderr);
	return () => {
		if (output.length === 0) return;
		console.error(`\nLast ${prefix} output:\n${output.join("")}`);
	};
}

async function waitForChromeDriver(child, port) {
	const deadline = Date.now() + 15_000;
	const statusUrl = `http://127.0.0.1:${port}/status`;
	let spawnError;
	const recordSpawnError = (error) => {
		spawnError = error;
	};
	child.once("error", recordSpawnError);
	try {
		while (Date.now() < deadline) {
			if (spawnError) throw spawnError;
			if (child.exitCode !== null) {
				throw new Error(
					`ChromeDriver exited before becoming ready (code ${child.exitCode}).`,
				);
			}
			try {
				const response = await fetch(statusUrl);
				if (response.ok) return;
			} catch {
				// ChromeDriver is still starting.
			}
			await new Promise((resolve) => setTimeout(resolve, 100));
		}
		throw new Error(`ChromeDriver did not become ready at ${statusUrl}.`);
	} finally {
		child.removeListener("error", recordSpawnError);
	}
}

async function terminateChild(child) {
	if (!child || child.exitCode !== null) return;
	if (!child.killed) child.kill("SIGTERM");
	await Promise.race([
		new Promise((resolve) => child.once("exit", resolve)),
		new Promise((resolve) => setTimeout(resolve, 3_000)),
	]);
	if (child.exitCode === null) child.kill("SIGKILL");
}

function waitForExit(child) {
	return new Promise((resolve, reject) => {
		child.once("error", reject);
		child.once("exit", (code, signal) => {
			if (Number.isInteger(code)) {
				resolve(code);
			} else {
				reject(new Error(`Process exited from signal ${signal ?? "unknown"}.`));
			}
		});
	});
}

async function main() {
	if (
		!Number.isFinite(timeoutMilliseconds) ||
		timeoutMilliseconds < 30_000
	) {
		throw new Error(
			"FLUTTER_WEB_INTEGRATION_TIMEOUT_MS must be at least 30000.",
		);
	}

	const driverPort = await reserveLoopbackPort();
	const chromeDriver = spawn(
		chromeDriverBinary,
		[`--port=${driverPort}`, "--allowed-ips=127.0.0.1"],
		{
			cwd: repositoryRoot,
			env: process.env,
			stdio: ["ignore", "pipe", "pipe"],
		},
	);
	const printDriverDiagnostics = captureProcessOutput(
		chromeDriver,
		"ChromeDriver",
	);
	let flutter;
	let timedOut = false;
	const stopOnSignal = async () => {
		await terminateChild(flutter);
		await terminateChild(chromeDriver);
	};
	process.once("SIGINT", stopOnSignal);
	process.once("SIGTERM", stopOnSignal);

	try {
		await waitForChromeDriver(chromeDriver, driverPort);
		const flutterArguments = [
			"drive",
			"--driver=test_driver/integration_test.dart",
			"--target=integration_test/firebase_environment_web_test.dart",
			"-d",
			"web-server",
			"--web-hostname=127.0.0.1",
			`--driver-port=${driverPort}`,
			"--headless",
			"--browser-name=chrome",
			"--timeout=180",
		];
		if (process.env.CHROME_BINARY) {
			flutterArguments.push(`--chrome-binary=${process.env.CHROME_BINARY}`);
		}
		flutter = spawn(flutterBinary, flutterArguments, {
			cwd: repositoryRoot,
			env: process.env,
			stdio: "inherit",
		});

		const exitCode = await Promise.race([
			waitForExit(flutter),
			new Promise((_, reject) => {
				setTimeout(() => {
					timedOut = true;
					reject(
						new Error(
							`Flutter web integration exceeded ${timeoutMilliseconds} ms.`,
						),
					);
				}, timeoutMilliseconds).unref();
			}),
		]);
		if (exitCode !== 0) {
			throw new Error(`flutter drive exited with code ${exitCode}.`);
		}
	} catch (error) {
		if (timedOut || chromeDriver.exitCode !== null) printDriverDiagnostics();
		throw error;
	} finally {
		process.removeListener("SIGINT", stopOnSignal);
		process.removeListener("SIGTERM", stopOnSignal);
		await terminateChild(flutter);
		await terminateChild(chromeDriver);
	}
}

main().catch((error) => {
	console.error(`Firebase environment web acceptance failed: ${error.stack}`);
	process.exitCode = 1;
});
