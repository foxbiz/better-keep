import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";

export const BETTER_KEEP_APPLE_BUNDLE_ID = "io.foxbiz.better-keep";

export function parseEnvironment(source) {
	const result = {};
	for (const line of String(source).split(/\r?\n/)) {
		const trimmed = line.trim();
		if (!trimmed || trimmed.startsWith("#")) continue;
		const separator = trimmed.indexOf("=");
		if (separator <= 0) continue;
		result[trimmed.slice(0, separator)] = trimmed.slice(separator + 1);
	}
	return result;
}

export function parseStringPlist(source) {
	const values = {};
	const pattern =
		/<key>([^<]+)<\/key>\s*<string>([^<]*)<\/string>/g;
	for (const match of String(source).matchAll(pattern)) {
		values[match[1]] = match[2];
	}
	return values;
}

export function parseProductBundleId(source) {
	return (
		/^\s*PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^\s#]+)\s*$/m.exec(
			String(source),
		)?.[1] ?? null
	);
}

export function appleFirebaseConfigurationViolations({
	environment,
	macosPlist,
	macosProductBundleId,
}) {
	const violations = [];

	function requireEqual(label, actual, expected) {
		if (!actual || !expected || actual !== expected) {
			violations.push(
				`${label} is "${actual ?? "<missing>"}", expected ` +
					`"${expected ?? "<missing>"}"`,
			);
		}
	}

	requireEqual(
		"iOS bundle ID",
		environment.IOS_BUNDLE_ID,
		BETTER_KEEP_APPLE_BUNDLE_ID,
	);
	requireEqual(
		"macOS bundle ID",
		environment.MACOS_BUNDLE_ID,
		BETTER_KEEP_APPLE_BUNDLE_ID,
	);
	requireEqual(
		"macOS Xcode bundle ID",
		macosProductBundleId,
		BETTER_KEEP_APPLE_BUNDLE_ID,
	);
	requireEqual(
		"macOS plist bundle ID",
		macosPlist.BUNDLE_ID,
		BETTER_KEEP_APPLE_BUNDLE_ID,
	);
	requireEqual(
		"macOS Firebase app ID",
		environment.MACOS_APP_ID,
		environment.IOS_APP_ID,
	);
	requireEqual(
		"macOS plist Firebase app ID",
		macosPlist.GOOGLE_APP_ID,
		environment.MACOS_APP_ID,
	);
	requireEqual(
		"macOS Firebase client ID",
		environment.MACOS_CLIENT_ID,
		environment.IOS_CLIENT_ID,
	);
	requireEqual(
		"macOS plist Firebase client ID",
		macosPlist.CLIENT_ID,
		environment.MACOS_CLIENT_ID,
	);
	requireEqual(
		"macOS Firebase project",
		macosPlist.PROJECT_ID,
		environment.MACOS_PROJECT_ID,
	);

	return violations;
}

export function verifyAppleFirebaseConfiguration({
	envPath,
	macosPlistPath,
	macosXcconfigPath,
}) {
	const environment = parseEnvironment(readFileSync(envPath, "utf8"));
	const macosPlist = parseStringPlist(
		readFileSync(macosPlistPath, "utf8"),
	);
	const macosProductBundleId = parseProductBundleId(
		readFileSync(macosXcconfigPath, "utf8"),
	);
	const violations = appleFirebaseConfigurationViolations({
		environment,
		macosPlist,
		macosProductBundleId,
	});
	if (violations.length > 0) {
		throw new Error(
			`Apple Firebase configuration mismatch:\n- ${violations.join("\n- ")}`,
		);
	}
}

function optionValue(arguments_, option) {
	const index = arguments_.indexOf(option);
	if (index === -1 || !arguments_[index + 1]) {
		throw new Error(`Missing required ${option} path`);
	}
	return arguments_[index + 1];
}

export function runAppleFirebaseConfigurationCli(arguments_) {
	try {
		verifyAppleFirebaseConfiguration({
			envPath: optionValue(arguments_, "--env"),
			macosPlistPath: optionValue(arguments_, "--macos-plist"),
			macosXcconfigPath: optionValue(arguments_, "--macos-xcconfig"),
		});
		process.stdout.write("Apple Firebase configuration verified.\n");
		return 0;
	} catch (error) {
		process.stderr.write(`${error.message}\n`);
		return 1;
	}
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	process.exitCode = runAppleFirebaseConfigurationCli(process.argv.slice(2));
}
