import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {resolveTestTask} from "../../tool/test_tasks.mjs";
import {MACOS_DEPLOYMENT_TARGET} from "../../tool/verify_macos_archive_config.mjs";

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const readRepositoryFile = (...segments) =>
	readFileSync(join(repositoryRoot, ...segments), "utf8");

const podfile = readRepositoryFile("macos", "Podfile");
const pubspec = readRepositoryFile("pubspec.yaml");
const runnerProject = readRepositoryFile(
	"macos",
	"Runner.xcodeproj",
	"project.pbxproj",
);

test("all macOS project configurations use the canonical deployment target", () => {
	const targets = [
		...runnerProject.matchAll(
			/^\s*MACOSX_DEPLOYMENT_TARGET = (?<version>[^;]+);$/gm,
		),
	].map((match) => match.groups.version);

	assert.deepEqual(targets, [
		MACOS_DEPLOYMENT_TARGET,
		MACOS_DEPLOYMENT_TARGET,
		MACOS_DEPLOYMENT_TARGET,
	]);
});

test("CocoaPods reuses the canonical macOS deployment target", () => {
	assert.match(
		podfile,
		new RegExp(
			`^MACOS_DEPLOYMENT_TARGET = '${MACOS_DEPLOYMENT_TARGET.replace(".", "\\.")}'\\.freeze$`,
			"m",
		),
	);
	assert.match(podfile, /^platform :osx, MACOS_DEPLOYMENT_TARGET$/m);
	assert.match(
		podfile,
		/config\.build_settings\['MACOSX_DEPLOYMENT_TARGET'\] = MACOS_DEPLOYMENT_TARGET/,
	);
});

test("the project keeps Flutter Swift Package Manager enabled", () => {
	assert.match(runnerProject, /FlutterGeneratedPluginSwiftPackage/);
	assert.doesNotMatch(pubspec, /enable-swift-package-manager:\s*false/);
});

test("macOS build policy runs in both focused and release test suites", () => {
	const policyOperations = [
		{
			args: ["--test", "test/tool/macos_build_policy_test.mjs"],
			command: "node",
			environment: {},
			type: "process",
		},
		{
			args: ["--test", "test/tool/macos_archive_config_test.mjs"],
			command: "node",
			environment: {},
			type: "process",
		},
	];

	assert.deepEqual(
		resolveTestTask(["macos-build-policy"]).operations,
		policyOperations,
	);
	for (const policyOperation of policyOperations) {
		assert.ok(
			resolveTestTask(["release"]).operations.some(
				(operation) =>
					operation.command === policyOperation.command &&
					operation.args.includes(policyOperation.args.at(-1)),
			),
		);
	}
});
