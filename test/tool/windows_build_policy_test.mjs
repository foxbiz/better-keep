import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const readRepositoryFile = (...segments) =>
	readFileSync(join(repositoryRoot, ...segments), "utf8");

const pubspec = readRepositoryFile("pubspec.yaml");
const pubspecLock = readRepositoryFile("pubspec.lock");
const windowsCmake = readRepositoryFile("windows", "CMakeLists.txt");
const backendChecksWorkflow = readRepositoryFile(
	".github",
	"workflows",
	"backend-checks.yml",
);
const buildReleaseWorkflow = readRepositoryFile(
	".github",
	"workflows",
	"build-release.yml",
);
const packageJson = JSON.parse(readRepositoryFile("package.json"));

function extractWorkflowJob(source, jobName) {
	const marker = `\n  ${jobName}:\n`;
	const start = source.indexOf(marker);
	assert.notEqual(start, -1, `workflow must define the ${jobName} job`);

	const bodyStart = start + marker.length;
	const remainder = source.slice(bodyStart);
	const nextJob = remainder.search(/\n  [a-zA-Z0-9_-]+:\n/);
	return nextJob === -1 ? remainder : remainder.slice(0, nextJob);
}

function parseVersion(version) {
	return version.split(".").map((part) => Number.parseInt(part, 10));
}

function compareVersions(left, right) {
	const leftParts = parseVersion(left);
	const rightParts = parseVersion(right);
	const partCount = Math.max(leftParts.length, rightParts.length);

	for (let index = 0; index < partCount; index += 1) {
		const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
		if (difference !== 0) {
			return Math.sign(difference);
		}
	}
	return 0;
}

test("gal resolves to the Visual Studio 2026-compatible release", () => {
	assert.match(pubspec, /^\s+gal:\s+\^2\.3\.3\s*$/m);

	const lockedGal = pubspecLock.match(
		/^\s{2}gal:\n[\s\S]*?^\s{4}version:\s+"(?<version>[^"]+)"\s*$/m,
	);
	assert.ok(lockedGal, "pubspec.lock must contain the gal package");
	assert.ok(
		compareVersions(lockedGal.groups.version, "2.3.3") >= 0,
		`gal ${lockedGal.groups.version} still enables the deprecated /await mode`,
	);
});

test("permission_handler_windows removes only its obsolete coroutine option", () => {
	assert.match(
		windowsCmake,
		/if\(MSVC AND TARGET permission_handler_windows_plugin\)/,
	);
	assert.match(
		windowsCmake,
		/get_target_property\([\s\S]*permission_handler_windows_plugin[\s\S]*COMPILE_OPTIONS[\s\S]*\)/,
	);
	assert.match(
		windowsCmake,
		/list\(\s*REMOVE_ITEM\s+PERMISSION_HANDLER_WINDOWS_COMPILE_OPTIONS\s+"\/await"\s*\)/,
	);
	assert.match(
		windowsCmake,
		/set_property\(\s*TARGET permission_handler_windows_plugin\s+PROPERTY COMPILE_OPTIONS/,
	);
	assert.doesNotMatch(
		windowsCmake,
		/_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS/,
	);
});

test("Windows verification and release builds use Visual Studio 2026", () => {
	const verificationJob = extractWorkflowJob(
		backendChecksWorkflow,
		"windows-build",
	);
	const releaseJob = extractWorkflowJob(buildReleaseWorkflow, "build-windows");

	for (const [name, job] of [
		["backend verification", verificationJob],
		["release", releaseJob],
	]) {
		assert.match(
			job,
			/runs-on:\s+windows-2025-vs2026/,
			`${name} must use the explicit Visual Studio 2026 image`,
		);
		assert.match(job, /run:\s+flutter pub get/);
		assert.match(job, /flutter build windows --release/);
	}
	assert.doesNotMatch(verificationJob, /secrets\./);
	assert.match(
		verificationJob,
		/build\/windows\/x64\/plugins\/gal\/gal_plugin\.vcxproj/,
	);
	assert.match(
		verificationJob,
		/build\/windows\/x64\/plugins\/permission_handler_windows\/permission_handler_windows_plugin\.vcxproj/,
	);
	assert.match(
		verificationJob,
		/Select-String -Path \$project -Pattern "\/await" -SimpleMatch -Quiet/,
	);
});

test("Windows policy runs in backend checks and the release gate", () => {
	const policyCommand = "npm run test:windows-build-policy";
	assert.equal(
		packageJson.scripts["test:windows-build-policy"],
		"node --test test/tool/windows_build_policy_test.mjs",
	);
	assert.match(packageJson.scripts["release:gate"], new RegExp(policyCommand));
	assert.match(backendChecksWorkflow, new RegExp(policyCommand));
});
