#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(scriptPath), "..");
export const NOTIFICATION_ICON_RESOURCE = "drawable/ic_stat_better_keep";

function listFilesRecursively(directory) {
	if (!fs.existsSync(directory)) return [];
	return fs.readdirSync(directory, {withFileTypes: true}).flatMap((entry) => {
		const entryPath = path.join(directory, entry.name);
		return entry.isDirectory() ? listFilesRecursively(entryPath) : [entryPath];
	});
}

function decodeLocalPropertiesValue(value) {
	return value.replaceAll("\\\\", "\\").replaceAll("\\:", ":");
}

export function findAndroidSdk(root = repositoryRoot, environment = process.env) {
	for (const candidate of [environment.ANDROID_SDK_ROOT, environment.ANDROID_HOME]) {
		if (candidate && fs.existsSync(candidate)) return candidate;
	}
	const propertiesPath = path.join(root, "android", "local.properties");
	if (!fs.existsSync(propertiesPath)) return null;
	const match = fs.readFileSync(propertiesPath, "utf8").match(/^sdk\.dir=(.+)$/m);
	return match ? decodeLocalPropertiesValue(match[1].trim()) : null;
}

export function findAapt2(root = repositoryRoot, environment = process.env) {
	const sdk = findAndroidSdk(root, environment);
	if (!sdk) return null;
	const executable = process.platform === "win32" ? "aapt2.exe" : "aapt2";
	const candidates = listFilesRecursively(path.join(sdk, "build-tools"))
		.filter((candidate) => path.basename(candidate) === executable)
		.sort((left, right) => left.localeCompare(right, undefined, {numeric: true}));
	return candidates.at(-1) ?? null;
}

export function findShrunkResourceArchive(root = repositoryRoot) {
	const candidates = listFilesRecursively(
		path.join(root, "build", "app", "intermediates", "shrunk_resources_proto_format", "release"),
	).filter((candidate) => candidate.endsWith(".ap_"));
	if (candidates.length === 0) return null;
	return candidates.sort(
		(left, right) => fs.statSync(right).mtimeMs - fs.statSync(left).mtimeMs,
	)[0];
}

export function resourceHasFilePayload(resourceDump, resourceName) {
	const lines = resourceDump.split(/\r?\n/);
	const resourceLine = lines.findIndex((line) =>
		new RegExp(`\\bresource\\s+0x[0-9a-f]+\\s+${resourceName.replace("/", "\\/")}\\s*$`, "i").test(line),
	);
	if (resourceLine < 0) return false;
	for (let index = resourceLine + 1; index < lines.length; index++) {
		if (/^\s*resource\s+0x[0-9a-f]+\s+/i.test(lines[index])) break;
		if (/\(file\)\s+res\//.test(lines[index])) return true;
	}
	return false;
}

export function verifyAndroidReleaseResources({
	root = repositoryRoot,
	environment = process.env,
	stderr = process.stderr,
	stdout = process.stdout,
} = {}) {
	const archive = findShrunkResourceArchive(root);
	const aapt2 = findAapt2(root, environment);
	if (!archive) {
		stderr.write("Android resource verification failed: no shrunk release resource archive was found.\n");
		return 1;
	}
	if (!aapt2) {
		stderr.write("Android resource verification failed: aapt2 was not found in the configured Android SDK.\n");
		return 1;
	}
	const result = spawnSync(aapt2, ["dump", "resources", archive], {
		encoding: "utf8",
		maxBuffer: 64 * 1024 * 1024,
	});
	if (result.status !== 0) {
		stderr.write(`Android resource verification failed: ${result.stderr || "aapt2 could not inspect the archive."}\n`);
		return 1;
	}
	if (!resourceHasFilePayload(result.stdout, NOTIFICATION_ICON_RESOURCE)) {
		stderr.write(
			`Android resource verification failed: ${NOTIFICATION_ICON_RESOURCE} has no file payload after shrinking.\n`,
		);
		return 1;
	}
	stdout.write(`Verified shrunk Android resource: ${NOTIFICATION_ICON_RESOURCE}\n`);
	return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === scriptPath) {
	process.exitCode = verifyAndroidReleaseResources();
}
