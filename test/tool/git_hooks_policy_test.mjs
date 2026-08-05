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
