import assert from "node:assert/strict";
import test from "node:test";
import {
	assertCompatibleFirebaseSdkPins,
	collectFlutterFireApplePins,
	parseFirebaseSdkVersion,
	runFlutterFireAppleSpmVerification,
} from "../../tool/verify_flutterfire_apple_spm.mjs";

const manifestFor = (version) => `
import PackageDescription

let firebaseSdkVersion: Version = "${version}"
`;

test("accepts matching FlutterFire Apple Firebase SDK pins", () => {
	const pins = [
		{packageName: "cloud_firestore", platform: "ios", version: "12.17.0"},
		{packageName: "firebase_core", platform: "ios", version: "12.17.0"},
	];

	assert.equal(assertCompatibleFirebaseSdkPins(pins), "12.17.0");
});

test("reports every package when FlutterFire Apple pins differ", () => {
	assert.throws(
		() =>
			assertCompatibleFirebaseSdkPins([
				{
					packageName: "cloud_firestore",
					platform: "ios",
					version: "12.15.0",
				},
				{
					packageName: "firebase_storage",
					platform: "ios",
					version: "12.17.0",
				},
			]),
		(error) => {
			assert.match(error.message, /cloud_firestore \(ios\): 12\.15\.0/);
			assert.match(error.message, /firebase_storage \(ios\): 12\.17\.0/);
			assert.match(error.message, /must use one exact Firebase SDK version/);
			return true;
		},
	);
});

test("rejects a Package.swift without exact Firebase SDK metadata", () => {
	assert.throws(
		() =>
			parseFirebaseSdkVersion("import PackageDescription", {
				packageName: "cloud_firestore",
				platform: "ios",
			}),
		/cloud_firestore ios Package\.swift does not declare an exact firebaseSdkVersion/,
	);
});

test("reports missing packages with the dependency recovery command", () => {
	assert.throws(
		() =>
			collectFlutterFireApplePins({
				packageConfigPath: "/repo/.dart_tool/package_config.json",
				packages: ["cloud_firestore"],
				platforms: ["ios"],
				readFile: (filePath) => {
					if (filePath.endsWith("package_config.json")) {
						return JSON.stringify({packages: []});
					}
					return manifestFor("12.17.0");
				},
			}),
		/cloud_firestore is missing.*flutter pub get/,
	);
});

test("CLI returns a useful failure for incompatible resolved packages", () => {
	let stderr = "";
	const packageConfigPath = "/repo/.dart_tool/package_config.json";
	const exitCode = runFlutterFireAppleSpmVerification({
		packageConfigPath,
		packages: ["cloud_firestore", "firebase_core"],
		platforms: ["ios"],
		readFile: (filePath) => {
			if (filePath === packageConfigPath) {
				return JSON.stringify({
					packages: [
						{name: "cloud_firestore", rootUri: "file:///packages/firestore"},
						{name: "firebase_core", rootUri: "file:///packages/core"},
					],
				});
			}
			return manifestFor(
				filePath.includes("cloud_firestore") ? "12.15.0" : "12.17.0",
			);
		},
		stderr: {write: (value) => (stderr += value)},
	});

	assert.equal(exitCode, 1);
	assert.match(stderr, /FlutterFire Apple Firebase SDK pins do not match/);
});
