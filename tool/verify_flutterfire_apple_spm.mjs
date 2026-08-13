#!/usr/bin/env node

import {readFileSync} from "node:fs";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

export const FLUTTERFIRE_APPLE_PACKAGES = Object.freeze([
	"cloud_firestore",
	"cloud_functions",
	"firebase_app_check",
	"firebase_auth",
	"firebase_core",
	"firebase_storage",
]);

export const APPLE_PACKAGE_PLATFORMS = Object.freeze(["ios", "macos"]);

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");
const defaultPackageConfigPath = path.join(
	repositoryRoot,
	".dart_tool",
	"package_config.json",
);

export function parseFirebaseSdkVersion(
	manifest,
	{packageName = "unknown package", platform = "Apple"} = {},
) {
	const match = manifest.match(
		/\blet\s+firebaseSdkVersion\s*:\s*Version\s*=\s*"(?<version>[^"]+)"/,
	);
	if (!match) {
		throw new Error(
			`${packageName} ${platform} Package.swift does not declare an exact firebaseSdkVersion.`,
		);
	}
	return match.groups.version;
}

export function assertCompatibleFirebaseSdkPins(pins) {
	if (pins.length === 0) {
		throw new Error("No FlutterFire Apple Firebase SDK pins were found.");
	}
	const versions = new Set(pins.map(({version}) => version));
	if (versions.size > 1) {
		const details = pins
			.map(
				({packageName, platform, version}) =>
					`- ${packageName} (${platform}): ${version}`,
			)
			.join("\n");
		throw new Error(
			`FlutterFire Apple Firebase SDK pins do not match:\n${details}\nAll FlutterFire Apple plugins must use one exact Firebase SDK version.`,
		);
	}
	return pins[0].version;
}

function readPackageConfig(packageConfigPath, readFile) {
	try {
		return JSON.parse(readFile(packageConfigPath, "utf8"));
	} catch (error) {
		if (error?.code === "ENOENT") {
			throw new Error(
				".dart_tool/package_config.json is missing. Run `flutter pub get` first.",
				{cause: error},
			);
		}
		if (error instanceof SyntaxError) {
			throw new Error(".dart_tool/package_config.json is not valid JSON.", {
				cause: error,
			});
		}
		throw error;
	}
}

function resolvePackageRoot(rootUri, packageConfigPath) {
	const configUrl = pathToFileURL(packageConfigPath);
	return fileURLToPath(new URL(rootUri, configUrl));
}

export function collectFlutterFireApplePins({
	packageConfigPath = defaultPackageConfigPath,
	packages = FLUTTERFIRE_APPLE_PACKAGES,
	platforms = APPLE_PACKAGE_PLATFORMS,
	readFile = readFileSync,
} = {}) {
	const packageConfig = readPackageConfig(packageConfigPath, readFile);
	const configuredPackages = new Map(
		packageConfig.packages?.map((entry) => [entry.name, entry]) ?? [],
	);
	const pins = [];

	for (const packageName of packages) {
		const packageEntry = configuredPackages.get(packageName);
		if (!packageEntry) {
			throw new Error(
				`${packageName} is missing from .dart_tool/package_config.json. Run \`flutter pub get\` first.`,
			);
		}
		const packageRoot = resolvePackageRoot(
			packageEntry.rootUri,
			packageConfigPath,
		);
		for (const platform of platforms) {
			const manifestPath = path.join(
				packageRoot,
				platform,
				packageName,
				"Package.swift",
			);
			let manifest;
			try {
				manifest = readFile(manifestPath, "utf8");
			} catch (error) {
				if (error?.code === "ENOENT") {
					throw new Error(
						`${packageName} ${platform} Package.swift is missing at ${manifestPath}. Run \`flutter pub get\` again.`,
						{cause: error},
					);
				}
				throw error;
			}
			pins.push({
				packageName,
				platform,
				version: parseFirebaseSdkVersion(manifest, {
					packageName,
					platform,
				}),
			});
		}
	}

	return pins;
}

export function verifyFlutterFireAppleSpm(options = {}) {
	const pins = collectFlutterFireApplePins(options);
	return {pins, version: assertCompatibleFirebaseSdkPins(pins)};
}

export function runFlutterFireAppleSpmVerification({
	stdout = process.stdout,
	stderr = process.stderr,
	...verificationOptions
} = {}) {
	try {
		const {pins, version} = verifyFlutterFireAppleSpm(verificationOptions);
		stdout.write(
			`Verified ${pins.length} FlutterFire Apple manifests on Firebase ${version}.\n`,
		);
		return 0;
	} catch (error) {
		stderr.write(`${error.message}\n`);
		return 1;
	}
}

if (path.resolve(process.argv[1] ?? "") === runnerPath) {
	process.exitCode = runFlutterFireAppleSpmVerification();
}
