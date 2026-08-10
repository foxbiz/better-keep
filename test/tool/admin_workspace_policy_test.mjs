import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import path from "node:path";

const repositoryRoot = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"../..",
);

test("admin workspace dependencies are ignored by git", () => {
	const output = execFileSync(
		"git",
		["check-ignore", "-v", "admin-site/node_modules"],
		{ cwd: repositoryRoot, encoding: "utf8" },
	);
	assert.match(output, /\/admin-site\/node_modules\//);
});
