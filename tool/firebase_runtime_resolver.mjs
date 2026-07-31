import {spawnSync} from "node:child_process";
import {homedir as defaultHomedir} from "node:os";
import path from "node:path";
import {
	FIREBASE_JAVA_HOME_ENV,
	FIREBASE_NODE_BIN_ENV,
	PINNED_JAVA_SDKMAN_ID,
	PINNED_JAVA_VERSION,
	PINNED_NODE_VERSION,
	extractJavaVersionLabel,
	isPinnedJavaVersion,
	isPinnedNodeVersion,
	normalizeNodeVersion,
} from "./firebase_runtime_policy.mjs";

function binaryName(name, platform) {
	return platform === "win32" ? `${name}.exe` : name;
}

function uniqueCandidates(candidates) {
	const seen = new Set();
	return candidates.filter((candidate) => {
		if (!candidate.path || seen.has(candidate.path)) {
			return false;
		}
		seen.add(candidate.path);
		return true;
	});
}

export function probeNodeVersion(
	nodeBin,
	spawnSyncImplementation = spawnSync,
) {
	const result = spawnSyncImplementation(nodeBin, ["--version"], {
		encoding: "utf8",
	});
	if (result.error || result.status !== 0) {
		return "";
	}
	return String(result.stdout || result.stderr || "").trim();
}

export function probeJavaVersion(
	javaBin,
	spawnSyncImplementation = spawnSync,
) {
	const result = spawnSyncImplementation(javaBin, ["-version"], {
		encoding: "utf8",
	});
	if (result.error || result.status !== 0) {
		return "";
	}
	return [result.stdout, result.stderr].filter(Boolean).join("\n");
}

function invalidOverrideMessage({environmentName, runtime, required, actual}) {
	return [
		`${environmentName} does not select the required ${runtime} ${required}.`,
		`Detected: ${actual || "unavailable"}.`,
		"Fix or unset the override before retrying.",
	].join("\n");
}

export function resolvePinnedNodeRuntime({
	processVersion = process.version,
	processExecPath = process.execPath,
	env = process.env,
	platform = process.platform,
	homeDirectory = defaultHomedir(),
	probeNode = probeNodeVersion,
} = {}) {
	const override = env[FIREBASE_NODE_BIN_ENV];
	if (override) {
		if (!path.isAbsolute(override)) {
			throw new Error(
				`${FIREBASE_NODE_BIN_ENV} must be an absolute path.`,
			);
		}
		const versionOutput = probeNode(override);
		if (!isPinnedNodeVersion(versionOutput)) {
			throw new Error(
				invalidOverrideMessage({
					environmentName: FIREBASE_NODE_BIN_ENV,
					runtime: "Node.js",
					required: PINNED_NODE_VERSION,
					actual: normalizeNodeVersion(versionOutput),
				}),
			);
		}
		return {
			bin: override,
			source: FIREBASE_NODE_BIN_ENV,
			version: PINNED_NODE_VERSION,
		};
	}

	if (isPinnedNodeVersion(processVersion)) {
		return {
			bin: processExecPath,
			source: "active process",
			version: PINNED_NODE_VERSION,
		};
	}

	const nvmRoot = env.NVM_DIR || path.join(homeDirectory, ".nvm");
	const nvmNode = path.join(
		nvmRoot,
		"versions",
		"node",
		`v${PINNED_NODE_VERSION}`,
		"bin",
		binaryName("node", platform),
	);
	const versionOutput = probeNode(nvmNode);
	if (isPinnedNodeVersion(versionOutput)) {
		return {
			bin: nvmNode,
			source: "NVM companion runtime",
			version: PINNED_NODE_VERSION,
		};
	}

	throw new Error(
		[
			`Firebase companion Node.js ${PINNED_NODE_VERSION} is not installed.`,
			`Install: nvm install ${PINNED_NODE_VERSION}`,
			`Optional override: ${FIREBASE_NODE_BIN_ENV}=/absolute/path/to/node`,
		].join("\n"),
	);
}

function discoverMacJavaHome(spawnSyncImplementation) {
	const result = spawnSyncImplementation(
		"/usr/libexec/java_home",
		["-v", "21"],
		{encoding: "utf8"},
	);
	if (result.error || result.status !== 0) {
		return "";
	}
	return String(result.stdout || "").trim();
}

export function resolvePinnedJavaRuntime({
	env = process.env,
	platform = process.platform,
	homeDirectory = defaultHomedir(),
	probeJava = probeJavaVersion,
	spawnSyncImplementation = spawnSync,
} = {}) {
	const override = env[FIREBASE_JAVA_HOME_ENV];
	if (override && !path.isAbsolute(override)) {
		throw new Error(
			`${FIREBASE_JAVA_HOME_ENV} must be an absolute path.`,
		);
	}
	const sdkmanCandidatesRoot =
		env.SDKMAN_CANDIDATES_DIR || path.join(homeDirectory, ".sdkman", "candidates");
	const candidates = uniqueCandidates([
		{
			home: override,
			path: override,
			source: FIREBASE_JAVA_HOME_ENV,
			strictOverride: Boolean(override),
		},
		{
			home: env.JAVA_HOME_21_X64,
			path: env.JAVA_HOME_21_X64,
			source: "JAVA_HOME_21_X64",
		},
		{
			home: env.JAVA_HOME,
			path: env.JAVA_HOME,
			source: "active JAVA_HOME",
		},
		{
			home: path.join(
				sdkmanCandidatesRoot,
				"java",
				PINNED_JAVA_SDKMAN_ID,
			),
			path: path.join(
				sdkmanCandidatesRoot,
				"java",
				PINNED_JAVA_SDKMAN_ID,
			),
			source: "SDKMAN companion runtime",
		},
	]);

	for (const candidate of candidates) {
		const javaBin = path.join(
			candidate.home,
			"bin",
			binaryName("java", platform),
		);
		const versionOutput = probeJava(javaBin);
		if (isPinnedJavaVersion(versionOutput)) {
			return {
				bin: javaBin,
				home: candidate.home,
				source: candidate.source,
				version: PINNED_JAVA_VERSION,
			};
		}
		if (candidate.strictOverride) {
			throw new Error(
				invalidOverrideMessage({
					environmentName: FIREBASE_JAVA_HOME_ENV,
					runtime: "Java",
					required: PINNED_JAVA_VERSION,
					actual: extractJavaVersionLabel(versionOutput),
				}),
			);
		}
	}

	if (platform === "darwin") {
		const macJavaHome = discoverMacJavaHome(spawnSyncImplementation);
		const javaBin = macJavaHome
			? path.join(macJavaHome, "bin", binaryName("java", platform))
			: "";
		const versionOutput = javaBin ? probeJava(javaBin) : "";
		if (isPinnedJavaVersion(versionOutput)) {
			return {
				bin: javaBin,
				home: macJavaHome,
				source: "macOS java_home",
				version: PINNED_JAVA_VERSION,
			};
		}
	}

	throw new Error(
		[
			`Firebase companion Java ${PINNED_JAVA_VERSION} is not installed.`,
			`Install: sdk install java ${PINNED_JAVA_SDKMAN_ID}`,
			`Optional override: ${FIREBASE_JAVA_HOME_ENV}=/absolute/path/to/jdk`,
		].join("\n"),
	);
}

function prependPath(currentPath, directory, delimiter) {
	if (!directory) {
		return currentPath || "";
	}
	return currentPath ? `${directory}${delimiter}${currentPath}` : directory;
}

export function buildRuntimeEnvironment({
	env = process.env,
	nodeRuntime,
	javaRuntime,
	platform = process.platform,
}) {
	const delimiter = platform === "win32" ? ";" : ":";
	let runtimePath = env.PATH || env.Path || "";
	runtimePath = prependPath(runtimePath, path.dirname(nodeRuntime.bin), delimiter);
	if (javaRuntime) {
		runtimePath = prependPath(
			runtimePath,
			path.join(javaRuntime.home, "bin"),
			delimiter,
		);
	}

	const result = {
		...env,
		PATH: runtimePath,
	};
	if (javaRuntime) {
		result.JAVA_HOME = javaRuntime.home;
	}
	return result;
}
