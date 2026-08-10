import assert from "node:assert/strict";
import test from "node:test";
import {
	MACOS_DEPLOYMENT_TARGET,
	runMacosArchiveConfigVerification,
	validateGeneratedPackageManifest,
	verifyMacosArchiveConfig,
} from "../../tool/verify_macos_archive_config.mjs";

const manifestFor = (version) => `
import PackageDescription

let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [
        .macOS("${version}")
    ]
)
`;

test("accepts the generated Swift package at the canonical macOS target", () => {
	assert.equal(
		validateGeneratedPackageManifest(manifestFor(MACOS_DEPLOYMENT_TARGET)),
		"13.3",
	);
});

test("rejects Flutter's stale default macOS deployment target", () => {
	assert.throws(
		() => validateGeneratedPackageManifest(manifestFor("10.15")),
		/macOS 10\.15; expected 13\.3/,
	);
});

test("reports a missing generated Swift package with the recovery command", () => {
	const missingFile = new Error("missing");
	missingFile.code = "ENOENT";
	assert.throws(
		() =>
			verifyMacosArchiveConfig({
				readFile: () => {
					throw missingFile;
				},
			}),
		/npm run build macos-xcode/,
	);
});

test("CLI verification returns a failure for an invalid generated manifest", () => {
	let stderr = "";
	const exitCode = runMacosArchiveConfigVerification({
		readFile: () => manifestFor("10.15"),
		stderr: {write: (value) => (stderr += value)},
	});

	assert.equal(exitCode, 1);
	assert.match(stderr, /expected 13\.3/);
});
