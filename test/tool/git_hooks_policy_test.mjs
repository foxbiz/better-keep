import assert from "node:assert/strict";
import {readdirSync, readFileSync} from "node:fs";
import path from "node:path";
import test from "node:test";

const repositoryRoot = path.resolve(import.meta.dirname, "../..");
const readRepositoryFile = (...segments) =>
	readFileSync(path.join(repositoryRoot, ...segments), "utf8");
const buildReleaseWorkflow = readRepositoryFile(
	".github",
	"workflows",
	"build-release.yml",
);

function extractWorkflowJob(source, jobName) {
	const marker = `\n  ${jobName}:\n`;
	const start = source.indexOf(marker);
	assert.notEqual(start, -1, `workflow must define the ${jobName} job`);

	const remainder = source.slice(start + marker.length);
	const nextJob = remainder.search(/\n  [a-zA-Z0-9_-]+:\n/);
	return nextJob === -1 ? remainder : remainder.slice(0, nextJob);
}

test("the tracked pre-commit hook runs the complete release gate", () => {
	const hook = readRepositoryFile(".githooks", "pre-commit");
	assert.match(hook, /^#!\/bin\/sh\s*$/m);
	assert.match(hook, /^exec npm run release\s*$/m);
});

test("only release artifact CI remains and local hook setup is documented", () => {
	assert.deepEqual(
		readdirSync(path.join(repositoryRoot, ".github", "workflows")).sort(),
		["build-release.yml"],
	);
	const readme = readRepositoryFile("README.md");
	assert.match(readme, /git config core\.hooksPath \.githooks/);
	assert.match(readme, /git commit --no-verify/);
	assert.match(readme, /version-matched\s+`chromedriver`/);
});

test("pull requests to main run only the portable release gate", () => {
	assert.match(
		buildReleaseWorkflow,
		/pull_request:\s*\n\s+branches:\s*\n\s+- main/,
	);
	assert.doesNotMatch(
		buildReleaseWorkflow.slice(
			buildReleaseWorkflow.indexOf("  release-gate:"),
			buildReleaseWorkflow.indexOf("  build-android:"),
		),
		/^\s+if:/m,
	);
	for (const job of ["build-android", "build-windows", "build-macos"]) {
		const definition = extractWorkflowJob(buildReleaseWorkflow, job);
		assert.match(definition, /if: github\.event_name == 'workflow_dispatch'/);
		assert.match(definition, /startsWith\(github\.ref, 'refs\/tags\/'\)/);
	}
});

test("macOS installs task-runner dependencies before Apple validation", () => {
	const job = extractWorkflowJob(buildReleaseWorkflow, "build-macos");
	assert.match(job, /uses:\s+actions\/setup-node@v6/);
	assert.match(job, /node-version-file:\s+\.nvmrc/);
	assert.match(job, /cache:\s+npm/);

	const nodeSetup = job.indexOf("uses: actions/setup-node@v6");
	const npmInstall = job.indexOf("run: npm ci");
	const flutterInstall = job.indexOf("run: flutter pub get");
	const appleValidation = job.indexOf("run: npm run check apple-config");
	const macosBuild = job.indexOf("run: flutter build macos --release");
	for (const [name, index] of Object.entries({
		nodeSetup,
		npmInstall,
		flutterInstall,
		appleValidation,
		macosBuild,
	})) {
		assert.notEqual(index, -1, `macOS job must define ${name}`);
	}
	assert.ok(nodeSetup < npmInstall);
	assert.ok(npmInstall < flutterInstall);
	assert.ok(flutterInstall < appleValidation);
	assert.ok(appleValidation < macosBuild);
});
