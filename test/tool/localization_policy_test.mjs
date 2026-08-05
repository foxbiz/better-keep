import assert from "node:assert/strict";
import {readdirSync, readFileSync} from "node:fs";
import path from "node:path";
import test from "node:test";
import {resolveTestTask} from "../../tool/test_tasks.mjs";

const repositoryRoot = path.resolve(import.meta.dirname, "../..");
const localizationDirectory = path.join(repositoryRoot, "lib/l10n");

function topLevelKeys(source) {
	const keys = [];
	let depth = 0;
	let inString = false;
	let escaped = false;
	for (let index = 0; index < source.length; index++) {
		const character = source[index];
		if (inString) {
			if (escaped) {
				escaped = false;
			} else if (character === "\\") {
				escaped = true;
			} else if (character === '"') {
				inString = false;
			}
			continue;
		}
		if (character === '"') {
			if (depth !== 1) {
				inString = true;
				continue;
			}
			let end = index + 1;
			let keyEscaped = false;
			for (; end < source.length; end++) {
				if (keyEscaped) {
					keyEscaped = false;
				} else if (source[end] === "\\") {
					keyEscaped = true;
				} else if (source[end] === '"') {
					break;
				}
			}
			const after = source.slice(end + 1).match(/^\s*:/);
			if (after) {
				keys.push(JSON.parse(source.slice(index, end + 1)));
			}
			index = end;
			continue;
		}
		if (character === "{") depth++;
		if (character === "}") depth--;
	}
	return keys;
}

function dartFiles(directory) {
	return readdirSync(directory, {withFileTypes: true}).flatMap((entry) => {
		const absolutePath = path.join(directory, entry.name);
		if (entry.isDirectory()) return dartFiles(absolutePath);
		return entry.name.endsWith(".dart") ? [absolutePath] : [];
	});
}

test("ARB catalogs have matching, unique message keys", () => {
	const arbFiles = readdirSync(localizationDirectory)
		.filter((name) => name.endsWith(".arb"))
		.sort();
	const catalogs = arbFiles.map((name) => {
		const source = readFileSync(path.join(localizationDirectory, name), "utf8");
		const keys = topLevelKeys(source);
		assert.equal(
			new Set(keys).size,
			keys.length,
			`${name} contains duplicate top-level keys`,
		);
		const parsed = JSON.parse(source);
		return {
			keys: Object.keys(parsed)
				.filter((key) => !key.startsWith("@"))
				.sort(),
			name,
		};
	});
	const english = catalogs.find(({name}) => name === "app_en.arb");
	assert.ok(english);
	for (const catalog of catalogs) {
		assert.deepEqual(catalog.keys, english.keys, `${catalog.name} key drift`);
	}
});

test("the release workflow runs the release suite with localization coverage", () => {
	const workflow = readFileSync(
		path.join(repositoryRoot, ".github/workflows/build-release.yml"),
		"utf8",
	);
	assert.match(workflow, /^\s*npm run release\s*$/m);
	assert.ok(
		resolveTestTask(["release"]).operations.some(
			(operation) =>
				operation.command === "node" &&
				operation.args.includes("test/tool/localization_policy_test.mjs"),
		),
	);
});

test("production presentation APIs do not contain hard-coded natural language", () => {
	const presentationRoots = ["components", "dialogs", "pages", "ui"].map(
		(directory) => path.join(repositoryRoot, "lib", directory),
	);
	const excluded = new Set([
		"lib/components/firebase_environment_banner.dart",
		"lib/pages/settings/nerd_stats_page.dart",
	]);
	const allowedValues = new Set([
		"Google",
		"INR (₹)",
		"USD ($)",
		"USD (\\$)",
		"contact@betterkeep.app",
		"foxbiz.io",
	]);
	const violations = [];
	const argumentPattern =
		/\bText\(\s*(?:const\s+)?(['"])(.*?)\1|\b(?:tooltip|semanticLabel|barrierLabel):\s*(['"])(.*?)\3/g;

	for (const file of presentationRoots.flatMap(dartFiles)) {
		const relativePath = path.relative(repositoryRoot, file);
		if (excluded.has(relativePath)) continue;
		const lines = readFileSync(file, "utf8").split(/\r?\n/);
		for (const [lineIndex, line] of lines.entries()) {
			if (line.trimStart().startsWith("//")) continue;
			argumentPattern.lastIndex = 0;
			for (const match of line.matchAll(argumentPattern)) {
				const value = match[2] ?? match[4] ?? "";
				if (
					value.startsWith("$") ||
					!/[\p{L}]/u.test(value) ||
					allowedValues.has(value)
				) {
					continue;
				}
				const debugSettingsValue =
					relativePath === "lib/pages/settings/settings.dart" &&
					(value === "Firebase environment" || value === "Close");
				if (!debugSettingsValue) {
					violations.push(`${relativePath}:${lineIndex + 1}: ${value}`);
				}
			}
		}
	}

	assert.deepEqual(violations, []);
});

test("raw exceptions and English status parsing cannot flow into production UI", () => {
	const productionFiles = [
		...dartFiles(path.join(repositoryRoot, "lib/components")),
		...dartFiles(path.join(repositoryRoot, "lib/dialogs")),
		...dartFiles(path.join(repositoryRoot, "lib/models")),
		...dartFiles(path.join(repositoryRoot, "lib/pages")),
		...dartFiles(path.join(repositoryRoot, "lib/ui")),
	];
	const forbiddenPatterns = [
		/Starting Firebase\.\.\./,
		/Technical details/i,
		/\.contains\(\s*['"]Complete['"]\s*\)/,
		/l10n\.\w+\(\s*(?:e|error|exception)\.toString\(\)/,
		/(?:Text|snackbar|_showError|_showSuccess)\([^;]{0,300}\b(?:e|error|exception)\.(?:message|toString\(\))/s,
	];
	const violations = [];
	for (const file of productionFiles) {
		const relativePath = path.relative(repositoryRoot, file);
		if (relativePath.endsWith("nerd_stats_page.dart")) continue;
		const source = readFileSync(file, "utf8");
		for (const pattern of forbiddenPatterns) {
			if (pattern.test(source)) violations.push(`${relativePath}: ${pattern}`);
		}
	}
	assert.deepEqual(violations, []);
});
