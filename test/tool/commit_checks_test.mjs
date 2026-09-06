import assert from "node:assert/strict";
import {execFileSync} from "node:child_process";
import {
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	writeFileSync,
} from "node:fs";
import {tmpdir} from "node:os";
import path from "node:path";
import test from "node:test";
import {
	affectedComponents,
	componentCommands,
	runCommitChecks,
} from "../../tool/commit_checks.mjs";

const cleanEnv = {...process.env};
for (const name of execFileSync("git", ["rev-parse", "--local-env-vars"], {
	encoding: "utf8",
})
	.trim()
	.split(/\s+/)) {
	delete cleanEnv[name];
}

function fixture(t) {
	const root = mkdtempSync(path.join(tmpdir(), "better-keep-commit-checks-"));
	t.after(() => rmSync(root, {recursive: true, force: true}));
	const git = (args, env = cleanEnv) =>
		execFileSync("git", args, {cwd: root, env, encoding: "utf8"});
	git(["init", "-q"]);
	const stage = (file, source, env = cleanEnv) => {
		mkdirSync(path.dirname(path.join(root, file)), {recursive: true});
		writeFileSync(path.join(root, file), source);
		git(["add", "--", file], env);
	};
	return {root, git, stage};
}

function harness(
	root,
	{processEnv = cleanEnv, formatCode = 0, processCode = 0, biomeOutput} = {},
) {
	const formats = [];
	const commands = [];
	let output = "";
	const options = {
		root,
		processEnv,
		stdout: {
			write: (value) => {
				output += value;
			},
		},
		stderr: {
			write: (value) => {
				output += value;
			},
		},
		capture: (operation) => {
			if (operation.command === "git") {
				return {
					exitCode: 0,
					stdout: execFileSync("git", operation.args, {
						cwd: root,
						env: operation.env,
						encoding: "utf8",
					}),
					stderr: "",
				};
			}
			formats.push(operation);
			return {
				exitCode: formatCode,
				stdout: biomeOutput ?? operation.input,
				stderr: "",
			};
		},
		runProcess: async (operation) => {
			commands.push(operation);
			return processCode;
		},
	};
	return {options, formats, commands, output: () => output};
}

test("selects owning components once, including tests and configuration", () => {
	for (const [files, expected] of [
		[
			[
				"lib/a.dart",
				"test/a_test.dart",
				"lib/l10n/app_en.arb",
				"pubspec.lock",
				"analysis_options.yaml",
			],
			["flutter"],
		],
		[
			[
				"functions/src/a.ts",
				"functions/test/a.test.js",
				"functions/package-lock.json",
				"functions/biome.json",
			],
			["functions"],
		],
		[["admin-site/tsconfig.json", "admin-site/src/a.astro"], ["admin-site"]],
		[["site/src/content/help.md", "test/site_assets_test.mjs"], ["site"]],
		[
			[
				"tool/check_tasks.mjs",
				".githooks/pre-commit",
				".github/workflows/build-release.yml",
				"firebase.deploy.json",
			],
			["tooling"],
		],
		[
			["package-lock.json", "package.json", ".nvmrc"],
			["admin-site", "site", "tooling"],
		],
		[["README.md", "functions/README.md", "docs/usage.md", "LICENSE"], []],
	])
		assert.deepEqual(affectedComponents(files), expected);
});

test("local commands exclude audits, release builds and integration suites", () => {
	const commands = [
		"flutter",
		"functions",
		"admin-site",
		"site",
		"tooling",
	].flatMap((name) => componentCommands(name));
	assert.deepEqual(componentCommands("flutter"), [
		{command: "flutter", args: ["analyze", "--no-pub"]},
		{command: "flutter", args: ["test", "--no-pub", "test"]},
	]);
	assert.deepEqual(componentCommands("functions"), [
		{command: "node", args: ["tool/test_tasks.mjs", "functions"]},
	]);
	for (const {args} of commands) {
		assert.ok(
			!args.some((arg) =>
				/^(audit|release|build|install|ci|test:mobile)$|emulators:|integration_test\//.test(
					arg,
				),
			),
		);
		assert.ok(
			!args.some((arg) =>
				/^test\/(emulator|firestore_rules|storage_rules)\//.test(arg),
			),
		);
	}
});

test("formatting reads the active alternate index and never edits or stages files", async (t) => {
	const {root, git, stage} = fixture(t);
	stage("README.md", "primary index\n");
	const processEnv = {
		...cleanEnv,
		GIT_INDEX_FILE: path.join(root, "alternate-index"),
		GIT_DIR: path.join(root, ".git"),
		GIT_WORK_TREE: root,
	};
	const file = "lib/a file.dart";
	stage(file, "void main(){ }\n", processEnv);
	writeFileSync(path.join(root, file), "void main() {}\n");
	const primaryIndex = readFileSync(path.join(root, ".git/index"));
	const alternateIndex = readFileSync(processEnv.GIT_INDEX_FILE);
	const h = harness(root, {processEnv, formatCode: 1});
	assert.equal(await runCommitChecks(h.options), 1);
	assert.equal(h.formats.length, 1);
	assert.equal(h.formats[0].input, "void main(){ }\n");
	assert.ok(h.formats[0].args.includes("--output=none"));
	assert.equal(h.formats[0].env.GIT_INDEX_FILE, undefined);
	assert.equal(h.commands.length, 0);
	assert.match(h.output(), /Staged formatting check failed: lib\/a file.dart/);
	assert.equal(readFileSync(path.join(root, file), "utf8"), "void main() {}\n");
	assert.deepEqual(readFileSync(path.join(root, ".git/index")), primaryIndex);
	assert.deepEqual(readFileSync(processEnv.GIT_INDEX_FILE), alternateIndex);
	assert.equal(git(["show", `:${file}`], processEnv), "void main(){ }\n");
});

test("checks both owners of renames and skips formatting deleted paths", async (t) => {
	const {root, git, stage} = fixture(t);
	stage("lib/old.dart", "void main() {}\n");
	// Seed HEAD without running a commit hook or changing any real repository.
	const tree = git(["write-tree"]).trim();
	const commit = git([
		"-c",
		"user.name=Test",
		"-c",
		"user.email=test@example.invalid",
		"commit-tree",
		tree,
		"-m",
		"fixture",
	]).trim();
	git(["update-ref", "HEAD", commit]);
	mkdirSync(path.join(root, "functions/src"), {recursive: true});
	git(["mv", "lib/old.dart", "functions/src/new.dart"]);
	const h = harness(root);
	assert.equal(await runCommitChecks(h.options), 0);
	assert.deepEqual(
		h.commands.map(({args}) => args),
		[
			["analyze", "--no-pub"],
			["test", "--no-pub", "test"],
			["tool/test_tasks.mjs", "functions"],
		],
	);
	assert.equal(h.formats.length, 1);
	assert.ok(
		h.formats[0].args.includes(path.join(root, "functions/src/new.dart")),
	);
});

test("formatting excludes generated code and unconfigured Functions files", async (t) => {
	const {root, stage} = fixture(t);
	stage("lib/l10n/app_localizations_en.dart", "generated\n");
	stage("lib/model.g.dart", "generated\n");
	stage("lib/firebase_options.dart", "// GENERATED CODE - DO NOT EDIT\n");
	stage("functions/scripts/helper.ts", "unconfigured\n");
	const h = harness(root);
	assert.equal(await runCommitChecks(h.options), 0);
	assert.equal(h.formats.length, 0);
	assert.equal(h.commands.length, 3);
});

test("Biome differences fail without emitting or writing formatted source", async (t) => {
	const {root, stage} = fixture(t);
	stage("functions/src/example.ts", "const x=1;\n");
	const h = harness(root, {biomeOutput: "const x = 1;\n"});
	assert.equal(await runCommitChecks(h.options), 1);
	assert.equal(h.formats[0].cwd, path.join(root, "functions"));
	assert.deepEqual(h.formats[0].args, [
		"format",
		"--stdin-file-path",
		path.join(root, "functions/src/example.ts"),
	]);
	assert.equal(
		readFileSync(path.join(root, "functions/src/example.ts"), "utf8"),
		"const x=1;\n",
	);
	assert.equal(h.commands.length, 0);
});

test("analysis failure stops tests and child commands have clean Git context", async (t) => {
	const {root, stage} = fixture(t);
	stage("lib/example.dart", "void main() {}\n");
	const h = harness(root, {
		processCode: 7,
		processEnv: {
			...cleanEnv,
			GIT_DIR: path.join(root, ".git"),
			GIT_WORK_TREE: root,
		},
	});
	assert.equal(await runCommitChecks(h.options), 7);
	assert.equal(h.commands.length, 1);
	assert.equal(h.commands[0].env.GIT_DIR, undefined);
	assert.equal(h.commands[0].env.GIT_WORK_TREE, undefined);
	assert.match(h.output(), /Commit checks failed: flutter/);
});

test("Dart formatting uses the installed Flutter SDK without a separate PATH entry", async (t) => {
	const {root, stage} = fixture(t);
	stage("lib/example.dart", "void main() {}\n");
	mkdirSync(path.join(root, ".dart_tool"));
	writeFileSync(
		path.join(root, ".dart_tool/package_config.json"),
		JSON.stringify({
			packages: [{name: "flutter", rootUri: "../sdk/packages/flutter"}],
		}),
	);
	const bin = path.join(root, "sdk/bin/cache/dart-sdk/bin");
	mkdirSync(bin, {recursive: true});
	const executable = path.join(
		bin,
		process.platform === "win32" ? "dart.exe" : "dart",
	);
	writeFileSync(executable, "");
	const h = harness(root);
	assert.equal(await runCommitChecks(h.options), 0);
	assert.equal(h.formats[0].command, executable);
});

test("documentation-only changes skip formatters and code checks", async (t) => {
	const {root, stage} = fixture(t);
	stage("docs/commit.md", "documentation\n");
	const h = harness(root);
	assert.equal(await runCommitChecks(h.options), 0);
	assert.equal(h.formats.length, 0);
	assert.equal(h.commands.length, 0);
});

test("missing Astro checkers fail before any install prompt or command runs", async (t) => {
	const {root, stage} = fixture(t);
	stage("site/src/example.ts", "export {};\n");
	const h = harness(root);
	assert.equal(await runCommitChecks(h.options), 1);
	assert.match(h.output(), /site requires installed @astrojs\/check/);
	assert.equal(h.commands.length, 0);
});
