#!/usr/bin/env node

import {readFileSync} from "node:fs";
import path from "node:path";
import {fileURLToPath} from "node:url";

export const MACOS_DEPLOYMENT_TARGET = "13.3";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");
export const generatedPackageManifestPath = path.join(
	repositoryRoot,
	"macos",
	"Flutter",
	"ephemeral",
	"Packages",
	"FlutterGeneratedPluginSwiftPackage",
	"Package.swift",
);

export function validateGeneratedPackageManifest(
	manifest,
	{expectedTarget = MACOS_DEPLOYMENT_TARGET} = {},
) {
	const platform = manifest.match(/\.macOS\("(?<version>[^"\n]+)"\)/);
	if (!platform) {
		throw new Error(
			"FlutterGeneratedPluginSwiftPackage does not declare a macOS platform version.",
		);
	}
	if (platform.groups.version !== expectedTarget) {
		throw new Error(
			`FlutterGeneratedPluginSwiftPackage targets macOS ${platform.groups.version}; expected ${expectedTarget}. Run \`npm run build macos-xcode\` again before opening Xcode.`,
		);
	}
	return platform.groups.version;
}

export function verifyMacosArchiveConfig({
	manifestPath = generatedPackageManifestPath,
	readFile = readFileSync,
} = {}) {
	let manifest;
	try {
		manifest = readFile(manifestPath, "utf8");
	} catch (error) {
		if (error?.code === "ENOENT") {
			throw new Error(
				"FlutterGeneratedPluginSwiftPackage is missing. Run `npm run build macos-xcode` before opening Xcode.",
				{cause: error},
			);
		}
		throw error;
	}
	return validateGeneratedPackageManifest(manifest);
}

export function runMacosArchiveConfigVerification({
	stdout = process.stdout,
	stderr = process.stderr,
	...verificationOptions
} = {}) {
	try {
		const target = verifyMacosArchiveConfig(verificationOptions);
		stdout.write(`macOS Xcode archive configuration targets ${target}.\n`);
		return 0;
	} catch (error) {
		stderr.write(`${error.message}\n`);
		return 1;
	}
}

if (path.resolve(process.argv[1] ?? "") === runnerPath) {
	process.exitCode = runMacosArchiveConfigVerification();
}
