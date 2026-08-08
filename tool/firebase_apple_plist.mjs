import {readFileSync, writeFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {parseEnvironment} from "./firebase_apple_config_policy.mjs";

const requiredEnvironmentKeys = [
	"MACOS_CLIENT_ID",
	"ANDROID_CLIENT_ID",
	"MACOS_API_KEY",
	"MACOS_MESSAGING_SENDER_ID",
	"MACOS_BUNDLE_ID",
	"MACOS_PROJECT_ID",
	"MACOS_STORAGE_BUCKET",
	"MACOS_APP_ID",
];

function requireEnvironmentValues(environment) {
	const missing = requiredEnvironmentKeys.filter(
		(key) => !String(environment[key] ?? "").trim(),
	);
	if (missing.length > 0) {
		throw new Error(
			`Cannot generate the macOS Firebase plist; missing ${missing.join(", ")}`,
		);
	}
}

function escapeXml(value) {
	return String(value)
		.replaceAll("&", "&amp;")
		.replaceAll("<", "&lt;")
		.replaceAll(">", "&gt;")
		.replaceAll('"', "&quot;")
		.replaceAll("'", "&apos;");
}

export function reverseClientId(clientId) {
	return String(clientId).split(".").reverse().join(".");
}

export function createMacosGoogleServicePlist(environment) {
	requireEnvironmentValues(environment);

	const stringValues = [
		["CLIENT_ID", environment.MACOS_CLIENT_ID],
		["REVERSED_CLIENT_ID", reverseClientId(environment.MACOS_CLIENT_ID)],
		["ANDROID_CLIENT_ID", environment.ANDROID_CLIENT_ID],
		["API_KEY", environment.MACOS_API_KEY],
		["GCM_SENDER_ID", environment.MACOS_MESSAGING_SENDER_ID],
		["PLIST_VERSION", "1"],
		["BUNDLE_ID", environment.MACOS_BUNDLE_ID],
		["PROJECT_ID", environment.MACOS_PROJECT_ID],
		["STORAGE_BUCKET", environment.MACOS_STORAGE_BUCKET],
	];
	const booleanValues = [
		["IS_ADS_ENABLED", false],
		["IS_ANALYTICS_ENABLED", false],
		["IS_APPINVITE_ENABLED", true],
		["IS_GCM_ENABLED", true],
		["IS_SIGNIN_ENABLED", true],
	];

	const entries = [
		...stringValues.map(
			([key, value]) =>
				`\t<key>${key}</key>\n\t<string>${escapeXml(value)}</string>`,
		),
		...booleanValues.map(
			([key, value]) =>
				`\t<key>${key}</key>\n\t<${value ? "true" : "false"}></${value ? "true" : "false"}>`,
		),
		`\t<key>GOOGLE_APP_ID</key>\n\t<string>${escapeXml(environment.MACOS_APP_ID)}</string>`,
	];

	return [
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
		'<plist version="1.0">',
		"<dict>",
		...entries,
		"</dict>",
		"</plist>",
		"",
	].join("\n");
}

function optionValue(arguments_, option) {
	const index = arguments_.indexOf(option);
	if (index === -1 || !arguments_[index + 1]) {
		throw new Error(`Missing required ${option} path`);
	}
	return arguments_[index + 1];
}

export function runMacosGoogleServicePlistCli(arguments_) {
	try {
		const envPath = optionValue(arguments_, "--env");
		const outputPath = optionValue(arguments_, "--output");
		const environment = parseEnvironment(readFileSync(envPath, "utf8"));
		writeFileSync(
			outputPath,
			createMacosGoogleServicePlist(environment),
			"utf8",
		);
		process.stdout.write(`Generated macOS Firebase plist at ${outputPath}.\n`);
		return 0;
	} catch (error) {
		process.stderr.write(`${error.message}\n`);
		return 1;
	}
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
	process.exitCode = runMacosGoogleServicePlistCli(process.argv.slice(2));
}
