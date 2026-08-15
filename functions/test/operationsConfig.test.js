const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "../..");

test("production deploy config and Firebase runtimes stay pinned", () => {
	const config = JSON.parse(
		fs.readFileSync(path.join(root, "firebase.deploy.json"), "utf8"),
	);
	const emulatorConfig = JSON.parse(
		fs.readFileSync(path.join(root, "firebase.emulators.json"), "utf8"),
	);
	const rootPackage = JSON.parse(
		fs.readFileSync(path.join(root, "package.json"), "utf8"),
	);
	assert.equal(config.functions.source, "functions");
	assert.equal(config.functions.runtime, "nodejs22");
	assert.deepEqual(config.functions.predeploy, [
		'npm --prefix "$RESOURCE_DIR" run validate:deploy-env',
		'npm --prefix "$RESOURCE_DIR" run build',
	]);
	assert.equal(emulatorConfig.functions.runtime, "nodejs22");
	assert.equal(rootPackage.engines.node, "22.x || 24.x");
	assert.equal(
		fs.readFileSync(path.join(root, ".nvmrc"), "utf8").trim(),
		"24.18.0",
	);
	assert.equal(fs.existsSync(path.join(root, ".sdkmanrc")), false);
	assert.match(
		rootPackage.scripts.functions,
		/tool\/functions_tasks\.mjs/,
	);
	assert.match(
		rootPackage.scripts.deploy,
		/tool\/deploy_tasks\.mjs/,
	);
	assert.equal(
		fs.readFileSync(path.join(root, ".npmrc"), "utf8").trim(),
		"engine-strict=true",
	);
	assert.equal(
		fs.readFileSync(path.join(root, "functions/.npmrc"), "utf8").trim(),
		"engine-strict=true",
	);
	assert.deepEqual(config.firestore, [
		{
			database: "better-keep",
			rules: "firestore.rules",
			indexes: "firestore.indexes.json",
		},
	]);
	assert.equal(config.storage.rules, "storage.rules");
});

test("all ephemeral collections have TTL field overrides", () => {
	const indexes = JSON.parse(
		fs.readFileSync(path.join(root, "firestore.indexes.json"), "utf8"),
	);
	const configured = new Map(
		indexes.fieldOverrides.map((entry) => [
			entry.collectionGroup,
			entry,
		]),
	);
	for (const [collection, fieldPath] of Object.entries({
		accountLinkSessions: "deleteAfter",
		pendingProviderLinks: "deleteAfter",
		oauthCompletions: "deleteAfter",
		oauthStates: "expiresAt",
		otpVerification: "expiresAt",
	})) {
		const entry = configured.get(collection);
		assert.equal(entry?.fieldPath, fieldPath, collection);
		assert.equal(entry?.ttl, true, collection);
		assert.deepEqual(entry?.indexes, [], collection);
	}
});
