import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const environmentExamples = [
	"admin-site/.env.example",
	"functions/.env.example",
];

function environmentAssignments(path) {
	return readFileSync(path, "utf8")
		.split(/\r?\n/u)
		.map((line) => line.trim())
		.filter((line) => line.length > 0 && !line.startsWith("#"))
		.map((line) => {
			const match = /^(?:export\s+)?([A-Z][A-Z0-9_]*)=/u.exec(line);
			assert.ok(match, `${path} contains an invalid assignment: ${line}`);
			return { key: match[1], line };
		});
}

test("environment examples contain valid, unique keys", () => {
	for (const path of environmentExamples) {
		const assignments = environmentAssignments(path);
		const keys = assignments.map(({ key }) => key);
		assert.equal(
			new Set(keys).size,
			keys.length,
			`${path} contains a duplicate environment key`,
		);
	}
});

test("Functions keeps one canonical SMTP username", () => {
	const emailUsers = environmentAssignments("functions/.env.example").filter(
		({ key }) => key === "EMAIL_USER",
	);
	assert.deepEqual(emailUsers, [
		{ key: "EMAIL_USER", line: "EMAIL_USER=contact@betterkeep.app" },
	]);
});
