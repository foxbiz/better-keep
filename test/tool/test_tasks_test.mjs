import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {
	TEST_SUITE_NAMES,
	formatTestTaskHelp,
	parseTestTaskArguments,
	resolveTestTask,
	runTestTask,
} from "../../tool/test_tasks.mjs";

test("root manifest exposes only grouped task entry points", () => {
	const packageJson = JSON.parse(readFileSync("package.json", "utf8"));
	assert.deepEqual(Object.keys(packageJson.scripts).sort(), [
		"build",
		"check",
		"deploy",
		"dev",
		"firebase",
		"functions",
		"release",
		"test",
	]);
	assert.equal(packageJson.scripts.build, "node tool/build_tasks.mjs");
	assert.equal(packageJson.scripts.check, "node tool/check_tasks.mjs");
	assert.equal(packageJson.scripts.deploy, "node tool/deploy_tasks.mjs");
	assert.equal(packageJson.scripts.dev, "node tool/dev_tasks.mjs");
	assert.equal(packageJson.scripts.firebase, "node tool/firebase_tasks.mjs");
	assert.equal(packageJson.scripts.functions, "node tool/functions_tasks.mjs");
	assert.equal(packageJson.scripts.release, "node tool/release_tasks.mjs");
	assert.equal(packageJson.scripts.test, "node tool/test_tasks.mjs");
	assert.deepEqual(
		Object.keys(packageJson.scripts).filter((name) => name.includes(":")),
		[],
	);
	for (const legacyName of [
		"analyze:firebase-environment",
		"audit:functions",
		"audit:runtime",
		"build:functions",
		"ci:functions",
		"deploy:backend",
		"firebase-emulators",
		"firebase:emulator-runtime-check",
		"firebase:indexes",
		"firebase:login",
		"firebase:runtime-check",
		"install:functions",
		"release:gate",
		"verify:firebase-apple-macos",
	]) {
		assert.equal(packageJson.scripts[legacyName], undefined);
	}
});

test("lists every supported suite and treats an omitted suite as help", () => {
	assert.deepEqual(parseTestTaskArguments([]), {help: true});
	assert.deepEqual(parseTestTaskArguments(["--help"]), {help: true});
	assert.deepEqual(TEST_SUITE_NAMES, [
		"client-sync",
		"database-migrations",
		"external-links",
		"firebase-apple",
		"firebase-emulator-android",
		"firebase-emulator-config",
		"firebase-emulator-functions",
		"firebase-emulator-review",
		"firebase-environment-android",
		"firebase-environment-web",
		"firebase-rules",
		"firebase-runtime",
		"functions",
		"hosting",
		"ios-build-policy",
		"keep-import",
		"lighthouse",
		"localization",
		"macos-build-policy",
		"mobile-web",
		"oauth-recovery",
		"release",
		"review-prompts",
		"search",
		"store",
		"subscription-management",
		"visibility",
		"web-release",
		"windows-build-policy",
	]);
	assert.match(formatTestTaskHelp(), /npm test <suite>/);
});

test("search suite validates site types, store metadata, and built visibility", () => {
	assert.deepEqual(resolveTestTask(["search"]).operations, [
		{
			args: [
				"--test",
				"test/site_account_manage_test.mjs",
				"test/site_assets_test.mjs",
				"test/site_public_documents_test.mjs",
				"test/site_public_stats_test.mjs",
				"test/site_share_viewer_test.mjs",
				"test/site_store_platform_test.mjs",
			],
			command: "node",
			environment: {},
			type: "process",
		},
		{
			args: ["--prefix", "site", "test"],
			command: "npm",
			environment: {},
			type: "process",
		},
		{
			args: ["--prefix", "site", "run", "check"],
			command: "npm",
			environment: {},
			type: "process",
		},
		{
			args: ["--prefix", "admin-site", "test"],
			command: "npm",
			environment: {},
			type: "process",
		},
		{
			args: ["--prefix", "admin-site", "run", "check"],
			command: "npm",
			environment: {},
			type: "process",
		},
		{
			args: ["scripts/validate_store_metadata.mjs"],
			command: "node",
			environment: {},
			type: "process",
		},
		{
			args: ["scripts/validate_visibility.mjs", "build/web"],
			command: "node",
			environment: {},
			type: "process",
		},
		{
			args: ["scripts/validate_admin_bundle.mjs", "build/admin"],
			command: "node",
			environment: {},
			type: "process",
		},
	]);
});

test("resolves individual process and pinned-runtime suites", () => {
	assert.deepEqual(resolveTestTask(["firebase-runtime"]).operations, [
		{
			args: [
				"--test",
				"test/tool/admin_workspace_policy_test.mjs",
				"test/tool/firebase_runtime_policy_test.mjs",
			],
			command: "node",
			environment: {},
			type: "process",
		},
	]);
	assert.deepEqual(resolveTestTask(["functions"]).operations, [
		{
			args: ["--", "npm", "--prefix", "functions", "test"],
			type: "functions",
		},
	]);
});

test("focused PR suites pin every required Flutter test path", () => {
	const expectedTests = {
		"database-migrations": ["test/database_merge_migration_test.dart"],
		"keep-import": [
			"test/google_keep_import_service_test.dart",
			"test/google_keep_import_discoverability_test.dart",
		],
		"review-prompts": ["test/review_prompt_service_test.dart"],
		"subscription-management": ["test/subscription_management_test.dart"],
	};

	for (const [suite, paths] of Object.entries(expectedTests)) {
		assert.deepEqual(resolveTestTask([suite]).operations, [
			{
				args: ["test", ...paths],
				command: "flutter",
				environment: {},
				type: "process",
			},
		]);
	}
});

test("web release builds the combined site before deterministic validation", () => {
	const operations = resolveTestTask(["web-release"]).operations;
	assert.deepEqual(operations[0], {
		args: [],
		command: "./scripts/build_web.sh",
		environment: {},
		type: "process",
	});
	assert.deepEqual(operations.at(-2), {
		args: ["--prefix", "site", "run", "test:mobile"],
		command: "npm",
		environment: {},
		type: "process",
	});
	assert.equal(operations.at(-1).type, "firebase");
	assert.deepEqual(operations.at(-1).args, [
		"--",
		"emulators:exec",
		"--only",
		"hosting",
		"--config",
		"firebase.emulators.json",
		"--project",
		"better-keep-notes",
		"./scripts/test_hosting_routes.sh",
	]);
});

test("hosting assertions avoid optional local-only search tools", () => {
	const script = readFileSync("scripts/test_hosting_routes.sh", "utf8");
	assert.doesNotMatch(script, /\brg\b/);
	assert.match(script, /grep -Eiq/);
});

test("release expands suites in the established order and excludes devices", () => {
	const release = resolveTestTask(["release"]);
	const serializedOperations = JSON.stringify(release.operations);
	const orderedMarkers = [
		"build_tasks_test.mjs",
		"billing_reconciliation_runner_test.mjs",
		"check_tasks_test.mjs",
		"dependency_override_policy_test.mjs",
		"environment_example_policy_test.mjs",
		"deploy_tasks_test.mjs",
		"dev_tasks_test.mjs",
		"firebase_tasks_test.mjs",
		"functions_tasks_test.mjs",
		"git_hooks_policy_test.mjs",
		"process_runner_test.mjs",
		"release_tasks_test.mjs",
		"test_tasks_test.mjs",
		"admin_workspace_policy_test.mjs",
		"firebase_runtime_policy_test.mjs",
		"ios_build_policy_test.mjs",
		"macos_build_policy_test.mjs",
		"macos_archive_config_test.mjs",
		"windows_build_policy_test.mjs",
		"database_merge_migration_test.dart",
		"build_web.sh",
		"site_assets_test.mjs",
		"test_hosting_routes.sh",
		"google_keep_import_service_test.dart",
		"google_keep_import_discoverability_test.dart",
		"review_prompt_service_test.dart",
		"subscription_management_test.dart",
		"localization_policy_test.mjs",
		'"functions","test"',
		"oauth_transaction_test.dart",
		"apple_auth_test.dart",
		"async_keyed_serializer_test.dart",
		"firebase_backend_boundary_test.dart",
		"run_flutter_web_integration.mjs",
		"test_firebase_rules.sh",
		"test:emulator",
		"review_isolation_acceptance_test.mjs",
	];
	let previousIndex = -1;
	for (const marker of orderedMarkers) {
		const index = serializedOperations.indexOf(marker);
		assert.ok(index > previousIndex, `${marker} must retain release order`);
		previousIndex = index;
	}
	assert.doesNotMatch(serializedOperations, /physical Android|hot restart/);
});

test("forwards arguments only to physical Android suites", () => {
	const android = resolveTestTask([
		"firebase-emulator-android",
		"-d",
		"pixel-9",
	]);
	assert.deepEqual(android.operations[0].args.slice(-2), ["-d", "pixel-9"]);
	assert.throws(
		() => resolveTestTask(["firebase-runtime", "unexpected"]),
		/does not accept extra arguments/,
	);
});

test("injects emulator-only environment values into Firebase operations", () => {
	const functionsSuite = resolveTestTask(["firebase-emulator-functions"]);
	assert.equal(functionsSuite.operations.at(-1).type, "firebase");
	assert.deepEqual(functionsSuite.operations.at(-1).environment, {
		OAUTH_LEGACY_V1_ENABLED: "true",
		OAUTH_STATE_SECRET: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	});
	const reviewSuite = resolveTestTask(["firebase-emulator-review"]);
	assert.equal(
		reviewSuite.operations.at(-1).environment
			.BETTER_KEEP_FUNCTIONS_EMULATOR_HOST,
		"127.0.0.1:15001",
	);
});

test("unknown suites fail with help and plain npm test succeeds", async () => {
	let stdout = "";
	assert.equal(
		await runTestTask([], {stdout: {write: (value) => (stdout += value)}}),
		0,
	);
	assert.match(stdout, /firebase-emulator-functions/);

	let stderr = "";
	assert.equal(
		await runTestTask(["missing"], {
			stderr: {write: (value) => (stderr += value)},
		}),
		2,
	);
	assert.match(stderr, /Unknown test suite: missing/);
	assert.match(stderr, /Usage: npm test/);
});

test("executes sequential operations and stops on the first failure", async () => {
	const calls = [];
	const exitCode = await runTestTask(["firebase-apple"], {
		processEnv: {BASE: "present"},
		runProcess: async (operation) => {
			calls.push(operation);
			return 7;
		},
	});
	assert.equal(exitCode, 7);
	assert.equal(calls.length, 1);
	assert.equal(calls[0].command, "flutter");
	assert.equal(calls[0].env.BASE, "present");
});

test("passes merged environments to Firebase without changing the parent", async () => {
	const originalLegacyValue = process.env.OAUTH_LEGACY_V1_ENABLED;
	const firebaseCalls = [];
	const exitCode = await runTestTask(["firebase-emulator-functions"], {
		processEnv: {BASE: "present"},
		runFirebase: async (args, options) => {
			firebaseCalls.push({args, options});
			return 0;
		},
		runFunctions: async () => 0,
	});
	assert.equal(exitCode, 0);
	assert.equal(firebaseCalls.length, 2);
	assert.equal(firebaseCalls[1].options.processEnv.BASE, "present");
	assert.equal(
		firebaseCalls[1].options.processEnv.OAUTH_LEGACY_V1_ENABLED,
		"true",
	);
	assert.equal(process.env.OAUTH_LEGACY_V1_ENABLED, originalLegacyValue);
});
