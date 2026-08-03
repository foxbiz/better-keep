const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const ts = require("typescript");
const {
	REVIEW_CALLABLE_EXEMPTIONS,
} = require("../lib/reviewCallableExemptions");
const { withNonReviewAccess } = require("../lib/nonReviewCallable");

const exportsDirectory = path.resolve(__dirname, "../src/exports");

function calledIdentifiers(source) {
	const sourceFile = ts.createSourceFile(
		"callable.ts",
		source,
		ts.ScriptTarget.ESNext,
		true,
		ts.ScriptKind.TS,
	);
	const names = new Set();
	function visit(node) {
		if (
			ts.isCallExpression(node) &&
			ts.isIdentifier(node.expression)
		) {
			names.add(node.expression.text);
		}
		ts.forEachChild(node, visit);
	}
	visit(sourceFile);
	return names;
}

test("every raw onCall export has an explicit review-isolation exemption", () => {
	const rawCallables = new Set();
	for (const entry of fs.readdirSync(exportsDirectory)) {
		if (!entry.endsWith(".ts")) continue;
		const source = fs.readFileSync(path.join(exportsDirectory, entry), "utf8");
		const calls = calledIdentifiers(source);
		if (calls.has("onCall")) {
			rawCallables.add(path.basename(entry, ".ts"));
		}
	}

	assert.deepEqual(
		[...rawCallables].sort(),
		Object.keys(REVIEW_CALLABLE_EXEMPTIONS).sort(),
		"Raw callable exports must be protected or explicitly exempted",
	);
	for (const [name, reason] of Object.entries(REVIEW_CALLABLE_EXEMPTIONS)) {
		assert.ok(rawCallables.has(name), `${name} is a stale exemption`);
		assert.ok(reason.length >= 20, `${name} needs a meaningful reason`);
	}
});

test("non-review wrapper fails closed for every protected review marker", () => {
	let handlerInvocations = 0;
	const wrapped = withNonReviewAccess((request) => {
		handlerInvocations += 1;
		return request.auth.uid;
	});
	assert.throws(() => wrapped({ data: {}, auth: undefined }), {
		code: "unauthenticated",
	});
	for (const token of [
		{ email: "review@betterkeep.app" },
		{ email: "person@example.com", appReview: true },
		{ email: "review@betterkeep.app", appReview: true },
	]) {
		assert.throws(
			() => wrapped({ data: {}, auth: { uid: "review", token } }),
			{ code: "permission-denied" },
		);
	}
	assert.equal(handlerInvocations, 0, "protected handlers must have no side effects");
	assert.equal(
		wrapped({
			data: {},
			auth: { uid: "ordinary", token: { email: "person@example.com" } },
		}),
		"ordinary",
	);
	assert.equal(handlerInvocations, 1);
});
