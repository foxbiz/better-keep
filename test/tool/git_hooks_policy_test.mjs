import assert from "node:assert/strict";
import {readdirSync, readFileSync} from "node:fs";
import path from "node:path";
import test from "node:test";

const repositoryRoot = path.resolve(import.meta.dirname, "../..");
const readRepositoryFile = (...segments) =>
	readFileSync(path.join(repositoryRoot, ...segments), "utf8");

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
	const workflow = readRepositoryFile(".github", "workflows", "build-release.yml");
	assert.match(workflow, /pull_request:\s*\n\s+branches:\s*\n\s+- main/);
	assert.doesNotMatch(
		workflow.slice(
			workflow.indexOf("  release-gate:"),
			workflow.indexOf("  build-android:"),
		),
		/^\s+if:/m,
	);
	for (const job of ["build-android", "build-windows", "build-macos"]) {
		const start = workflow.indexOf(`  ${job}:`);
		const remainder = workflow.slice(start + 1);
		const nextJobMatch = remainder.match(/\n  [A-Za-z][\w-]*:\n/);
		const nextJob = nextJobMatch
			? start + 1 + nextJobMatch.index
			: -1;
		const definition = workflow.slice(start, nextJob < 0 ? undefined : nextJob);
		assert.match(definition, /if: github\.event_name == 'workflow_dispatch'/);
		assert.match(definition, /startsWith\(github\.ref, 'refs\/tags\/'\)/);
	}
});
