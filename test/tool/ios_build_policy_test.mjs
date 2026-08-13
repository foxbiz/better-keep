import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {resolveTestTask} from "../../tool/test_tasks.mjs";

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const readRepositoryFile = (...segments) =>
	readFileSync(join(repositoryRoot, ...segments), "utf8");

const iosPodfile = readRepositoryFile("ios", "Podfile");
const pubspec = readRepositoryFile("pubspec.yaml");
const runnerProject = readRepositoryFile(
	"ios",
	"Runner.xcodeproj",
	"project.pbxproj",
);

test("cloud_firestore uses the immutable upstream Android transaction fix", () => {
	assert.match(
		pubspec,
		/cloud_firestore:\n\s+git:\n\s+url: https:\/\/github\.com\/firebase\/flutterfire\.git\n\s+ref: f949c23d795a9d843ffd1c6deea285a4d9ce5ff3\n\s+path: packages\/cloud_firestore\/cloud_firestore/,
	);
	assert.match(pubspec, /flutterfire#18553/);
});

test("all iOS project configurations tolerate generated framework imports", () => {
	const values = [
		...runnerProject.matchAll(
			/^\s*CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER = (?<value>\w+);$/gm,
		),
	].map((match) => match.groups.value);

	assert.deepEqual(values, ["NO", "NO", "NO"]);
});

test("Whisper remains a dynamic CocoaPods framework for Dart FFI", () => {
	const frameworkDirectives = [
		...iosPodfile.matchAll(/^\s*use_frameworks!(?<options>.*)$/gm),
	];

	assert.equal(frameworkDirectives.length, 1);
	assert.equal(
		frameworkDirectives[0].groups.options.trim(),
		"",
		"use_frameworks! must not opt into static linkage because Whisper symbols are resolved at runtime",
	);
});

test("iOS build policy runs in both focused and release test suites", () => {
	const policyOperations = [
		{
			args: [
				"--test",
				"test/tool/flutterfire_apple_spm_test.mjs",
				"test/tool/ios_build_policy_test.mjs",
			],
			command: "node",
			environment: {},
			type: "process",
		},
		{
			args: ["tool/verify_flutterfire_apple_spm.mjs"],
			command: "node",
			environment: {},
			type: "process",
		},
	];

	assert.deepEqual(
		resolveTestTask(["ios-build-policy"]).operations,
		policyOperations,
	);
	const releaseOperations = resolveTestTask(["release"]).operations;
	for (const expected of policyOperations) {
		assert.ok(
			releaseOperations.some(
				(operation) => JSON.stringify(operation) === JSON.stringify(expected),
			),
		);
	}
});
