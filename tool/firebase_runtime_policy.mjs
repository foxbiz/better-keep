export const PINNED_NODE_VERSION = "22.23.1";
export const PINNED_JAVA_VERSION = "21.0.11";
export const PINNED_JAVA_SDKMAN_ID = "21.0.11-tem";
export const FIREBASE_NODE_BIN_ENV = "BETTER_KEEP_FIREBASE_NODE_BIN";
export const FIREBASE_JAVA_HOME_ENV = "BETTER_KEEP_FIREBASE_JAVA_HOME";
export const FIREBASE_REEXEC_ENV = "BETTER_KEEP_FIREBASE_NODE_REEXEC";
export const FIREBASE_HOST_NODE_ENV = "BETTER_KEEP_FIREBASE_HOST_NODE";

export function parseNodeMajor(version) {
	const match = /^v?(\d+)(?:\.|$)/.exec(String(version ?? "").trim());
	return match ? Number.parseInt(match[1], 10) : null;
}

export function normalizeNodeVersion(version) {
	const match = /^v?(\d+\.\d+\.\d+)$/.exec(
		String(version ?? "").trim(),
	);
	return match?.[1] ?? null;
}

export function parseJavaMajor(versionOutput) {
	const version = extractJavaVersionLabel(versionOutput);
	if (!version) {
		return null;
	}

	const legacyMatch = /^1\.(\d+)(?:[._+-]|$)/.exec(version);
	if (legacyMatch) {
		return Number.parseInt(legacyMatch[1], 10);
	}

	const modernMatch = /^(\d+)(?:[._+-]|$)/.exec(version);
	return modernMatch ? Number.parseInt(modernMatch[1], 10) : null;
}

export function extractJavaVersionLabel(versionOutput) {
	const output = String(versionOutput ?? "");
	return (
		/\b(?:openjdk|java) version "([^"]+)"/i.exec(output)?.[1] ??
		/\b(?:openjdk|java) (\d+(?:[._+-]\S*)?)/i.exec(output)?.[1] ??
		null
	);
}

export function normalizeJavaVersion(versionOutput) {
	const version = extractJavaVersionLabel(versionOutput);
	if (!version) {
		return null;
	}
	const match = /^(\d+\.\d+\.\d+)$/.exec(version);
	return match?.[1] ?? null;
}

export function isPinnedNodeVersion(version) {
	return normalizeNodeVersion(version) === PINNED_NODE_VERSION;
}

export function isPinnedJavaVersion(versionOutput) {
	return normalizeJavaVersion(versionOutput) === PINNED_JAVA_VERSION;
}

export function firebaseCommandRequiresJava(firebaseArgs) {
	const command = firebaseArgs.find(
		(argument) =>
			argument === "emulators:start" || argument === "emulators:exec",
	);
	if (command !== "emulators:start" && command !== "emulators:exec") {
		return false;
	}

	const onlyIndex = firebaseArgs.findIndex(
		(argument) => argument === "--only" || argument.startsWith("--only="),
	);
	if (onlyIndex === -1) {
		return true;
	}

	const onlyArgument = firebaseArgs[onlyIndex];
	const productsValue = onlyArgument.startsWith("--only=")
		? onlyArgument.slice("--only=".length)
		: firebaseArgs[onlyIndex + 1];
	if (!productsValue || productsValue.startsWith("-")) {
		return true;
	}

	const javaBackedProducts = new Set(["database", "firestore", "storage"]);
	return productsValue
		.split(",")
		.map((product) => product.trim())
		.some((product) => javaBackedProducts.has(product));
}

export function formatRuntimeReport({
	hostNodeVersion,
	firebaseNode,
	javaRuntime,
	requireJava,
}) {
	const lines = [
		"Firebase runtime selection:",
		`- Host Node.js: ${String(hostNodeVersion).replace(/^v/, "")}`,
		`- Firebase Node.js: ${firebaseNode.version} (${firebaseNode.source})`,
	];
	if (requireJava) {
		lines.push(
			`- Firebase Java: ${javaRuntime.version} (${javaRuntime.source})`,
		);
	} else {
		lines.push("- Firebase Java: not required for this command");
	}
	return lines.join("\n");
}
