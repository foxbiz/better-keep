import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {
	BETTER_KEEP_APPLE_BUNDLE_ID,
	appleFirebaseConfigurationViolations,
	parseEnvironment,
	parseProductBundleId,
	parseStringPlist,
} from "../../tool/firebase_apple_config_policy.mjs";

const validEnvironment = {
	IOS_APP_ID: "1:123:ios:correct",
	IOS_BUNDLE_ID: BETTER_KEEP_APPLE_BUNDLE_ID,
	IOS_CLIENT_ID: "ios-client",
	MACOS_APP_ID: "1:123:ios:correct",
	MACOS_BUNDLE_ID: BETTER_KEEP_APPLE_BUNDLE_ID,
	MACOS_CLIENT_ID: "ios-client",
	MACOS_PROJECT_ID: "better-keep-notes",
};
const validPlist = {
	BUNDLE_ID: BETTER_KEEP_APPLE_BUNDLE_ID,
	CLIENT_ID: "ios-client",
	GOOGLE_APP_ID: "1:123:ios:correct",
	PROJECT_ID: "better-keep-notes",
};

test("parses environment, plist, and xcconfig identifiers", () => {
	assert.deepEqual(
		parseEnvironment("IOS_APP_ID=app-id\n# comment\nEMPTY=\n"),
		{IOS_APP_ID: "app-id", EMPTY: ""},
	);
	assert.deepEqual(
		parseStringPlist(
			"<key>BUNDLE_ID</key><string>io.foxbiz.better-keep</string>",
		),
		{BUNDLE_ID: BETTER_KEEP_APPLE_BUNDLE_ID},
	);
	assert.equal(
		parseProductBundleId(
			"PRODUCT_BUNDLE_IDENTIFIER = io.foxbiz.better-keep\n",
		),
		BETTER_KEEP_APPLE_BUNDLE_ID,
	);
});

test("accepts the shared correctly registered Apple Firebase app", () => {
	assert.deepEqual(
		appleFirebaseConfigurationViolations({
			environment: validEnvironment,
			macosPlist: validPlist,
			macosProductBundleId: BETTER_KEEP_APPLE_BUNDLE_ID,
		}),
		[],
	);
});

test("rejects the stale template macOS registration", () => {
	const violations = appleFirebaseConfigurationViolations({
		environment: {
			...validEnvironment,
			MACOS_APP_ID: "1:123:ios:template",
		},
		macosPlist: {
			...validPlist,
			BUNDLE_ID: "com.example.betterKeep",
			GOOGLE_APP_ID: "1:123:ios:template",
		},
		macosProductBundleId: "io.foxbiz.better_keep",
	});

	assert.match(violations.join("\n"), /com\.example\.betterKeep/);
	assert.match(violations.join("\n"), /1:123:ios:template/);
	assert.match(violations.join("\n"), /io\.foxbiz\.better_keep/);
});

test("tracked macOS xcconfig uses the production bundle identifier", () => {
	const source = readFileSync("macos/Runner/Configs/AppInfo.xcconfig", "utf8");
	assert.equal(parseProductBundleId(source), BETTER_KEEP_APPLE_BUNDLE_ID);
	assert.doesNotMatch(source, /com\.example|better_keep/);
});

test("startup validates the committed Apple app before Auth initialization", () => {
	const source = readFileSync("lib/main.dart", "utf8");
	const validation = source.indexOf(
		"validateActiveAppleFirebaseConfiguration(",
	);
	const lock = source.indexOf("FirebaseBackend.lock();");
	const authInitialization = source.indexOf("AuthService.init(");

	assert.notEqual(validation, -1);
	assert.ok(validation < lock, "Apple Firebase validation must precede locking");
	assert.ok(lock < authInitialization, "Firebase must lock before Auth starts");
});
