#!/usr/bin/env node

import {existsSync, readFileSync, readdirSync} from "node:fs";
import {createRequire} from "node:module";
import path from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import crossSpawn from "cross-spawn";
import {
	actionableProcessStartError,
	runChildProcess,
} from "./process_runner.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");
const componentOrder = [
	"flutter",
	"functions",
	"admin-site",
	"site",
	"tooling",
];

function isDocumentation(file) {
	return (
		!file.startsWith("site/src/") &&
		(/\.(md|mdx|txt)$/i.test(file) || /(^|\/)(LICENSE|NOTICE)(\.|$)/.test(file))
	);
}

export function affectedComponents(files) {
	const components = new Set();
	for (const file of files) {
		if (isDocumentation(file)) continue;
		if (
			["package.json", "package-lock.json", ".npmrc", ".nvmrc"].includes(file)
		) {
			for (const name of ["tooling", "admin-site", "site"])
				components.add(name);
		} else if (/^functions\//.test(file)) {
			components.add("functions");
		} else if (/^admin-site\//.test(file)) {
			components.add("admin-site");
		} else if (/^site\/|^test\/site_.*\.mjs$/.test(file)) {
			components.add("site");
		} else if (
			file.endsWith(".dart") ||
			/^(lib|assets|integration_test|android|ios|macos|windows|linux|web)\//.test(
				file,
			) ||
			file.startsWith("test/goldens/") ||
			[
				"pubspec.yaml",
				"pubspec.lock",
				"analysis_options.yaml",
				"l10n.yaml",
				".metadata",
			].includes(file)
		) {
			components.add("flutter");
		} else if (
			/^(tool|scripts|test|\.githooks|\.github)\//.test(file) ||
			/^(firebase|firestore|storage)[.-]/.test(file) ||
			[".gitignore", ".firebaserc", ".env.example"].includes(file)
		) {
			components.add("tooling");
		}
	}
	return componentOrder.filter((name) => components.has(name));
}

function testFiles(root, directory, pattern) {
	return readdirSync(path.join(root, directory))
		.filter((file) => pattern.test(file))
		.sort()
		.map((file) => `${directory}/${file}`);
}

export function componentCommands(component, root = repositoryRoot) {
	const step = (command, ...args) => ({command, args});
	switch (component) {
		case "flutter":
			return [
				step("flutter", "analyze", "--no-pub"),
				step("flutter", "test", "--no-pub", "test"),
			];
		case "functions":
			// This existing command compiles once, checks scripts, then runs unit tests.
			return [step("node", "tool/test_tasks.mjs", "functions")];
		case "admin-site":
			return [
				step("npm", "--prefix", "admin-site", "run", "check"),
				step("npm", "--prefix", "admin-site", "test"),
			];
		case "site":
			return [
				step("npm", "--prefix", "site", "run", "check"),
				step("npm", "--prefix", "site", "test"),
				step(
					"node",
					"--test",
					...testFiles(root, "test", /^site_.*_test\.mjs$/),
				),
			];
		case "tooling":
			return [
				step("node", "--test", ...testFiles(root, "test/tool", /_test\.mjs$/)),
			];
		default:
			throw new Error(`Unknown commit-check component: ${component}`);
	}
}

function captureOutput({command, args, cwd, env, input}) {
	const result = crossSpawn.sync(command, args, {
		cwd,
		env,
		input,
		encoding: "utf8",
		maxBuffer: 64 * 1024 * 1024,
	});
	if (result.error) throw actionableProcessStartError(command, result.error);
	return {
		exitCode: result.status ?? 1,
		stdout: result.stdout ?? "",
		stderr: result.stderr ?? "",
	};
}

function isGenerated(file, source) {
	return (
		/\.(g|freezed|mocks)\.dart$/.test(file) ||
		/^lib\/l10n\/app_localizations.*\.dart$/.test(file) ||
		/^\s*\/\/.*(GENERATED CODE|DO NOT EDIT)/m.test(source.slice(0, 500))
	);
}

function dartExecutable(root) {
	// Use the project's installed Flutter SDK even when only `flutter` is on PATH.
	const configPath = path.join(root, ".dart_tool/package_config.json");
	if (existsSync(configPath)) {
		const config = JSON.parse(readFileSync(configPath, "utf8"));
		const flutter = config.packages.find((entry) => entry.name === "flutter");
		if (flutter) {
			const packageRoot = fileURLToPath(
				new URL(flutter.rootUri, pathToFileURL(configPath)),
			);
			const executable = path.resolve(
				packageRoot,
				"../../bin/cache/dart-sdk/bin",
				process.platform === "win32" ? "dart.exe" : "dart",
			);
			if (existsSync(executable)) return executable;
		}
	}
	return "dart";
}

export async function runCommitChecks({
	root = repositoryRoot,
	processEnv = process.env,
	capture = captureOutput,
	runProcess = runChildProcess,
	stdout = process.stdout,
	stderr = process.stderr,
} = {}) {
	try {
		const git = (...args) => {
			const result = capture({
				command: "git",
				args,
				cwd: root,
				env: processEnv,
			});
			if (result.exitCode !== 0)
				throw new Error(result.stderr || "Unable to read staged changes.");
			return result.stdout;
		};
		// Keep Git's temporary/alternate index until staged paths and blobs are read.
		// Child tests may use their own repositories, so they must not inherit it.
		const childEnv = {...processEnv};
		for (const variable of git("rev-parse", "--local-env-vars")
			.trim()
			.split(/\s+/)) {
			delete childEnv[variable];
		}
		const diffArgs = ["diff", "--cached", "--name-only", "--no-renames", "-z"];
		const files = git(...diffArgs)
			.split("\0")
			.filter(Boolean);
		const components = affectedComponents(files);
		if (components.length === 0) {
			stdout.write("No staged code changes require commit checks.\n");
			return 0;
		}
		const existingFiles = git(...diffArgs, "--diff-filter=ACM")
			.split("\0")
			.filter(Boolean);
		for (const file of existingFiles) {
			const dart = file.endsWith(".dart");
			const biome =
				/^functions\/src\/.*\.(ts|tsx|js|jsx|mjs|cjs|json|jsonc)$/.test(file);
			if (!dart && !biome) continue;
			const source = git("show", `:${file}`);
			if (isGenerated(file, source)) continue;
			const command = dart
				? dartExecutable(root)
				: path.join(
						root,
						"functions/node_modules/.bin",
						process.platform === "win32" ? "biome.cmd" : "biome",
					);
			const args = dart
				? [
						"format",
						"--output=none",
						"--set-exit-if-changed",
						"--stdin-name",
						path.join(root, file),
					]
				: ["format", "--stdin-file-path", path.join(root, file)];
			const result = capture({
				command,
				args,
				cwd: dart ? root : path.join(root, "functions"),
				env: childEnv,
				input: source,
			});
			if (result.exitCode !== 0 || (biome && result.stdout !== source)) {
				stderr.write(
					`Staged formatting check failed: ${file}\n${result.stderr}`,
				);
				const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
				const fix = dart
					? `${quote(command)} format ${quote(file)}`
					: `(cd functions && node_modules/.bin/biome format --write ${quote(file.slice("functions/".length))})`;
				stderr.write(
					`Fix with: ${fix}\nReview and stage the formatting changes before committing.\n`,
				);
				return result.exitCode || 1;
			}
		}
		for (const component of components) {
			stdout.write(`Commit checks: ${component}\n`);
			if (component === "admin-site" || component === "site") {
				// Astro otherwise offers to install missing checkers during `check`.
				const require = createRequire(
					path.join(root, component, "package.json"),
				);
				for (const dependency of ["@astrojs/check", "typescript"]) {
					try {
						require.resolve(dependency);
					} catch {
						throw new Error(
							`${component} requires installed ${dependency}. Run npm ci before committing.`,
						);
					}
				}
			}
			for (const step of componentCommands(component, root)) {
				const code = await runProcess({...step, cwd: root, env: childEnv});
				if (code !== 0) {
					stderr.write(
						`Commit checks failed: ${component} (${step.command} ${step.args.join(" ")})\n`,
					);
					return code;
				}
			}
		}
		return 0;
	} catch (error) {
		stderr.write(`Unable to run commit checks: ${error.message}\n`);
		return 1;
	}
}

if (process.argv[1] && path.resolve(process.argv[1]) === runnerPath) {
	process.exitCode = await runCommitChecks();
}
