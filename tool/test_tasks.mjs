#!/usr/bin/env node

import path from "node:path";
import { chromeBinary } from "./chrome_binary.mjs";
import { fileURLToPath } from "node:url";
import { runFirebaseCli } from "./firebase_cli.mjs";
import { runFunctionsCommand } from "./functions_runtime.mjs";
import { runChildProcess } from "./process_runner.mjs";

const runnerPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(runnerPath), "..");
const projectId = "better-keep-notes";
const emulatorOAuthEnvironment = {
	OAUTH_LEGACY_V1_ENABLED: "true",
	OAUTH_STATE_SECRET: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
};

const processStep = (command, args, environment = {}) => ({
	args,
	command,
	environment,
	type: "process",
});
const firebaseStep = (args, environment = {}) => ({
	args,
	environment,
	type: "firebase",
});
const functionsStep = (args) => ({ args, type: "functions" });
const suiteStep = (name) => ({ name, type: "suite" });

function defineSuite(
	description,
	createSteps,
	{ acceptsArguments = false } = {},
) {
	return { acceptsArguments, createSteps, description };
}

function flutterTests(files) {
	return processStep("flutter", ["test", ...files]);
}

function webReleaseChecks() {
	return [
		processStep("./scripts/build_web.sh", []),
		...["false", "true"].map((beta) =>
			processStep(
				"flutter",
				[
					"test",
					"--no-pub",
					"--platform",
					"chrome",
					`--dart-define=WEB_BETA=${beta}`,
					"test/web_release_test.dart",
				],
				{ CHROME_EXECUTABLE: chromeBinary() },
			),
		),
		suiteStep("search"),
		suiteStep("web-logout"),
		suiteStep("mobile-web"),
		suiteStep("hosting"),
		processStep("node", [
			"--test",
			"test/web/beta_launcher_test.mjs",
			"test/web/firebase_emulator_auth_restart_test.mjs",
			"test/web/checkout_loading_test.mjs",
		]),
	];
}

const suites = {
	"device-pairing": defineSuite(
		"Run pairing protocol, service, and UI regressions.",
		() => [
			flutterTests([
				"test/device_pairing_code_test.dart",
				"test/srp_pairing_library_test.dart",
				"test/device_approval_service_test.dart",
				"test/device_verification_test.dart",
				"test/device_verification_widget_test.dart",
			]),
		],
	),
	"firebase-emulator-pairing": defineSuite(
		"Run pairing in isolated demo emulators and Chrome.",
		() => [
			firebaseStep(
				[
					"--",
					"emulators:exec",
					"--only",
					"auth,firestore",
					"--project",
					"demo-better-keep-pairing",
					"--config",
					"firebase.emulator-tests.json",
					"flutter test --no-pub --platform chrome test/emulator/device_pairing.dart",
				],
				{ CHROME_EXECUTABLE: chromeBinary() },
			),
		],
	),
	"client-sync": defineSuite("Run client synchronization tests.", () => [
		flutterTests([
			"test/async_keyed_serializer_test.dart",
			"test/home_system_title_test.dart",
			"test/sketch_preview_repair_service_test.dart",
			"test/storage_logout_test.dart",
			"test/sync_presentation_test.dart",
			"test/cloud_sync_cursor_test.dart",
			"test/e2ee_sync_readiness_test.dart",
			"test/firestore_sync_resilience_test.dart",
			"test/initial_hydration_gate_test.dart",
			"test/remote_attachment_payload_test.dart",
			"test/remote_content_apply_coordinator_test.dart",
			"test/remote_content_failure_state_test.dart",
			"test/remote_content_retry_ledger_test.dart",
			"test/remote_document_revision_test.dart",
			"test/remote_local_id_resolver_test.dart",
			"test/remote_sync_cache_service_test.dart",
			"test/storage_object_locator_test.dart",
			"test/sync_refresh_serialization_test.dart",
		]),
	]),
	"database-migrations": defineSuite("Run database migration tests.", () => [
		flutterTests(["test/database_merge_migration_test.dart"]),
	]),
	"external-links": defineSuite("Check links in the built website.", () => [
		processStep("node", ["scripts/check_external_links.mjs", "build/web"]),
	]),
	"firebase-apple": defineSuite("Run Apple Firebase and Auth tests.", () => [
		flutterTests([
			"test/apple_auth_test.dart",
			"test/auth_error_messages_test.dart",
			"test/cloud_functions_helper_test.dart",
			"test/firebase_apple_configuration_test.dart",
			"test/login_page_apple_auth_test.dart",
		]),
		processStep("node", [
			"--test",
			"test/tool/firebase_apple_config_policy_test.mjs",
		]),
	]),
	"firebase-emulator-auth-recovery": defineSuite(
		"Run signup, account switching and recovery on an iOS or Android emulator.",
		(extraArgs) => [
			processStep("flutter", [
				"test",
				"integration_test/auth_recovery_emulator_test.dart",
				"--dart-define-from-file=.env",
				...extraArgs,
			]),
		],
		{ acceptsArguments: true },
	),
	"firebase-emulator-android": defineSuite(
		"Run the physical Android download smoke test.",
		(extraArgs) => [
			processStep("flutter", [
				"test",
				"integration_test/firebase_emulator_smoke_test.dart",
				"--plain-name",
				"physical Android downloads note documents and attachments through production repositories",
				"--dart-define-from-file=.env",
				...extraArgs,
			]),
		],
		{ acceptsArguments: true },
	),
	"firebase-emulator-config": defineSuite(
		"Run Firebase environment configuration tests.",
		() => [
			flutterTests([
				"test/firebase_backend_boundary_test.dart",
				"test/firebase_bootstrap_coordinator_test.dart",
				"test/firebase_emulator_config_test.dart",
				"test/firebase_emulator_google_auth_test.dart",
				"test/firebase_emulator_host_test.dart",
				"test/firebase_storage_emulator_transport_test.dart",
				"test/firebase_environment_banner_test.dart",
				"test/firebase_local_data_isolation_test.dart",
				"test/firebase_selection_screen_test.dart",
				"test/reminder_session_service_test.dart",
				"test/reminder_navigation_service_test.dart",
			]),
		],
	),
	"firebase-emulator-deletion": defineSuite(
		"Run account deletion safety tests in isolated demo emulators.",
		() => [
			functionsStep([
				"--",
				"npm",
				"--prefix",
				"functions",
				"run",
				"test:deletion",
			]),
		],
	),
	"firebase-emulator-functions": defineSuite(
		"Run Functions tests in isolated Firebase emulators.",
		() => [
			firebaseStep(["--check-only", "--require-java"]),
			functionsStep(["--", "npm", "--prefix", "functions", "run", "build"]),
			firebaseStep(
				[
					"--",
					"emulators:exec",
					"--only",
					"auth,firestore,functions,storage",
					"--config",
					"firebase.emulator-tests.json",
					"--project",
					projectId,
					"npm --prefix functions run test:emulator",
				],
				emulatorOAuthEnvironment,
			),
		],
	),
	"firebase-emulator-review": defineSuite(
		"Run the managed review account acceptance test.",
		() => [
			firebaseStep(["--check-only", "--require-java"]),
			functionsStep(["--", "npm", "--prefix", "functions", "run", "build"]),
			firebaseStep(
				[
					"--",
					"emulators:exec",
					"--only",
					"auth,firestore,functions,storage",
					"--config",
					"firebase.emulator-tests.json",
					"--project",
					projectId,
					"node --test test/emulator/review_isolation_acceptance_test.mjs",
				],
				{
					...emulatorOAuthEnvironment,
					BETTER_KEEP_FUNCTIONS_EMULATOR_HOST: "127.0.0.1:15001",
				},
			),
		],
	),
	"firebase-environment-android": defineSuite(
		"Run the physical Android environment-switching test.",
		(extraArgs) => [
			processStep("flutter", [
				"test",
				"integration_test/firebase_emulator_smoke_test.dart",
				"--plain-name",
				"hot restart can switch Emulator to Live and back without app contamination",
				"--dart-define-from-file=.env",
				...extraArgs,
			]),
		],
		{ acceptsArguments: true },
	),
	"firebase-environment-web": defineSuite(
		"Run web policy and browser acceptance tests.",
		() => [
			processStep("node", [
				"--test",
				"test/tool/firebase_web_banner_policy_test.mjs",
			]),
			processStep("node", ["tool/run_flutter_web_integration.mjs"]),
		],
	),
	"firebase-rules": defineSuite(
		"Run Firestore and Storage security rules tests.",
		() => [processStep("./tool/test_firebase_rules.sh", [])],
	),
	"firebase-runtime": defineSuite("Run Firebase runtime policy tests.", () => [
		processStep("node", [
			"--test",
			"test/tool/admin_workspace_policy_test.mjs",
			"test/tool/firebase_runtime_policy_test.mjs",
		]),
	]),
	functions: defineSuite("Run Cloud Functions unit tests.", () => [
		functionsStep(["--", "npm", "--prefix", "functions", "test"]),
	]),
	hosting: defineSuite(
		"Validate routes in an isolated Hosting emulator.",
		() => [
			firebaseStep([
				"--",
				"emulators:exec",
				"--only",
				"hosting",
				"--config",
				"firebase.emulators.json",
				"--project",
				projectId,
				"./scripts/test_hosting_routes.sh",
			]),
		],
	),
	"keep-import": defineSuite(
		"Run Google Keep import reliability tests.",
		() => [
			flutterTests([
				"test/google_keep_import_service_test.dart",
				"test/google_keep_import_discoverability_test.dart",
			]),
		],
	),
	lighthouse: defineSuite("Audit the marketing site with Lighthouse.", () => [
		processStep("npm", ["--prefix", "site", "run", "lighthouse"]),
	]),
	localization: defineSuite(
		"Generate and verify production localization.",
		() => [
			processStep("flutter", ["gen-l10n"]),
			processStep("node", ["--test", "test/tool/localization_policy_test.mjs"]),
			flutterTests([
				"test/auth_error_messages_test.dart",
				"test/device_localizations_test.dart",
				"test/firebase_startup_error_view_test.dart",
				"test/localized_common_surfaces_test.dart",
				"test/progress_localizations_test.dart",
				"test/reminder_schedule_result_presenter_test.dart",
			]),
		],
	),
	"mobile-web": defineSuite(
		"Run the marketing homepage mobile browser acceptance test.",
		() => [processStep("npm", ["--prefix", "site", "run", "test:mobile"])],
	),
	"oauth-recovery": defineSuite("Run OAuth recovery tests.", () => [
		processStep("node", [
			"--test",
			"test/tool/oauth_hosting_verifier_test.mjs",
		]),
		flutterTests([
			"test/oauth_transaction_test.dart",
			"test/recovered_oauth_sign_in_coordinator_test.dart",
		]),
	]),
	"review-prompts": defineSuite("Run review prompt behavior tests.", () => [
		flutterTests(["test/review_prompt_service_test.dart"]),
	]),
	reminders: defineSuite("Run reminder reliability tests.", () => [
		flutterTests([
			"test/due_reminder_presenter_test.dart",
			"test/note_set_reminder_test.dart",
			"test/notification_initialization_recovery_test.dart",
			"test/reminder_action_processor_test.dart",
			"test/reminder_action_receipt_service_test.dart",
			"test/reminder_action_ui_handoff_test.dart",
			"test/reminder_navigation_service_test.dart",
			"test/reminder_notification_plan_test.dart",
			"test/reminder_notification_registration_test.dart",
			"test/reminder_schedule_concurrency_test.dart",
			"test/reminder_session_service_test.dart",
			"test/reminder_sync_codec_test.dart",
			"test/reminder_test.dart",
			"test/reminder_time_zone_resolver_test.dart",
		]),
	]),
	search: defineSuite("Validate site types and search visibility.", () => [
		processStep("node", [
			"--experimental-strip-types",
			"--test",
			"test/site_account_manage_test.mts",
			"test/site_assets_test.mts",
			"test/site_public_documents_test.mts",
			"test/site_public_stats_test.mts",
			"test/site_share_viewer_test.mts",
			"test/site_store_platform_test.mts",
		]),
		processStep("npm", ["--prefix", "site", "test"]),
		processStep("npm", ["--prefix", "site", "run", "check"]),
		processStep("npm", ["--prefix", "admin-site", "test"]),
		processStep("npm", ["--prefix", "admin-site", "run", "check"]),
		processStep("node", ["scripts/validate_visibility.mjs", "build/web"]),
		processStep("node", ["scripts/validate_admin_bundle.mjs", "build/admin"]),
	]),
	"subscription-management": defineSuite(
		"Run subscription management routing tests.",
		() => [flutterTests(["test/subscription_management_test.dart"])],
	),
	visibility: defineSuite(
		"Validate the built website's search visibility.",
		() => [
			processStep("node", ["scripts/validate_visibility.mjs", "build/web"]),
		],
	),
	"web-sign-out-lock": defineSuite(
		"Verify browser approval, cross-window sign-out, and reload in stable and beta builds.",
		() => ["false", "true"].map((beta) =>
			processStep(
				"flutter",
				["test", "--no-pub", "--platform", "chrome", `--dart-define=WEB_BETA=${beta}`, "test/web_sign_out_lock_test.dart", "test/e2ee_browser_storage_test.dart"],
				{ CHROME_EXECUTABLE: chromeBinary() },
			),
		),
	),
	"web-logout": defineSuite(
		"Verify sign-out cleanup in both browser file stores.",
		() => [
			suiteStep("web-sign-out-lock"),
			processStep(
				"flutter",
				["test", "--no-pub", "--platform", "chrome", "test/web_storage_recovery_test.dart"],
				{ CHROME_EXECUTABLE: chromeBinary() },
			),
			...["OPFS", "IndexedDB"].map((backend) =>
				processStep("node", [
					"tool/run_flutter_web_integration.mjs",
					"integration_test/account_file_cleanup_test.dart",
					`--dart-define=TEST_STORAGE_BACKEND=${backend}`,
					...(backend === "IndexedDB"
						? [
								"--web-browser-flag=--disable-blink-features=FileSystemAccessOriginPrivate",
							]
						: []),
				]),
			),
		],
	),
	"offline-browser": defineSuite(
		"Verify offline startup and revocation in stable and beta browsers.",
		() => [
			firebaseStep(
				[
					"emulators:exec",
					"--only",
					"auth,firestore",
					"--project",
					"demo-better-keep-pairing",
					"--config",
					"firebase.emulator-tests.json",
					"node test/emulator/offline_browser.mjs",
				],
				{ CHROME_EXECUTABLE: chromeBinary() },
			),
		],
	),
	"web-release": defineSuite(
		"Build and validate the combined Flutter and Astro website.",
		() => [...webReleaseChecks(), suiteStep("offline-browser")],
	),
	"image-share": defineSuite("Run image sharing regression tests.", () => [
		flutterTests([
			"test/shared_image_note_service_test.dart",
			"test/ios_image_share_inbox_test.dart",
			"test/image_attachment_preparation_service_test.dart",
			"test/intent_handler_pending_test.dart",
		]),
		processStep("node", ["--test", "test/tool/image_share_native_test.mjs"]),
		processStep("node", ["--test", "test/tool/image_share_signing_test.mjs"]),
	]),
	"ios-build-policy": defineSuite("Run iOS build policy tests.", () => [
		processStep("node", [
			"--test",
			"test/tool/flutterfire_apple_spm_test.mjs",
			"test/tool/ios_build_policy_test.mjs",
		]),
		processStep("node", ["tool/verify_flutterfire_apple_spm.mjs"]),
	]),
	"macos-build-policy": defineSuite("Run macOS build policy tests.", () => [
		processStep("node", ["--test", "test/tool/macos_build_policy_test.mjs"]),
		processStep("node", ["--test", "test/tool/macos_archive_config_test.mjs"]),
	]),
	release: defineSuite("Run every non-device release test suite.", () => [
		suiteStep("release-core"),
		suiteStep("offline-browser"),
	]),
	"release-core": defineSuite("Run release checks covered by the core CI job.", () => [
		processStep("node", [
			"--test",
			"test/tool/android_release_resource_policy_test.mjs",
			"test/tool/build_tasks_test.mjs",
			"test/tool/chrome_binary_test.mjs",
			"test/tool/beta_web_test.mjs",
			"test/tool/hosting_release_test.mjs",
			"test/tool/billing_reconciliation_runner_test.mjs",
			"test/tool/check_tasks_test.mjs",
			"test/tool/dependency_override_policy_test.mjs",
			"test/tool/environment_example_policy_test.mjs",
			"test/tool/deploy_tasks_test.mjs",
			"test/tool/dev_tasks_test.mjs",
			"test/tool/firebase_tasks_test.mjs",
			"test/tool/functions_tasks_test.mjs",
			"test/tool/git_hooks_policy_test.mjs",
			"test/tool/process_runner_test.mjs",
			"test/tool/release_tasks_test.mjs",
			"test/tool/test_tasks_test.mjs",
		]),
		suiteStep("device-pairing"),
		suiteStep("firebase-emulator-pairing"),
		suiteStep("firebase-runtime"),
		suiteStep("ios-build-policy"),
		suiteStep("macos-build-policy"),
		suiteStep("windows-build-policy"),
		suiteStep("database-migrations"),
		suiteStep("image-share"),
		...webReleaseChecks(),
		suiteStep("keep-import"),
		suiteStep("review-prompts"),
		suiteStep("reminders"),
		suiteStep("subscription-management"),
		suiteStep("localization"),
		suiteStep("functions"),
		suiteStep("oauth-recovery"),
		suiteStep("firebase-apple"),
		suiteStep("client-sync"),
		suiteStep("firebase-emulator-config"),
		suiteStep("firebase-environment-web"),
		suiteStep("firebase-rules"),
		suiteStep("firebase-emulator-functions"),
		suiteStep("firebase-emulator-deletion"),
		suiteStep("firebase-emulator-review"),
	]),
	"windows-build-policy": defineSuite("Run Windows build policy tests.", () => [
		processStep("node", ["--test", "test/tool/windows_build_policy_test.mjs"]),
	]),
};

export const TEST_SUITE_NAMES = Object.freeze(Object.keys(suites).sort());

export function parseTestTaskArguments(argv) {
	if (argv.length === 0 || argv[0] === "--help" || argv[0] === "help") {
		return { help: true };
	}
	const [suite, ...extraArgs] = argv;
	const definition = suites[suite];
	if (!definition) {
		throw new Error(`Unknown test suite: ${suite}`);
	}
	if (!definition.acceptsArguments && extraArgs.length > 0) {
		throw new Error(
			`The ${suite} test suite does not accept extra arguments: ${extraArgs.join(" ")}`,
		);
	}
	return { extraArgs, help: false, suite };
}

function expandSuite(name, extraArgs = [], stack = []) {
	if (stack.includes(name)) {
		throw new Error(
			`Test suite dependency cycle: ${[...stack, name].join(" -> ")}`,
		);
	}
	const operations = [];
	for (const step of suites[name].createSteps(extraArgs)) {
		if (step.type === "suite") {
			operations.push(...expandSuite(step.name, [], [...stack, name]));
		} else {
			operations.push(step);
		}
	}
	return operations;
}

export function resolveTestTask(argv) {
	const parsed = parseTestTaskArguments(argv);
	if (parsed.help) {
		return parsed;
	}
	return {
		description: suites[parsed.suite].description,
		help: false,
		operations: expandSuite(parsed.suite, parsed.extraArgs),
		suite: parsed.suite,
	};
}

export function formatTestTaskHelp() {
	return [
		"Usage: npm test <suite> [arguments]",
		"",
		...TEST_SUITE_NAMES.map(
			(name) => `${name.padEnd(30)} ${suites[name].description}`,
		),
	].join("\n");
}

async function executeOperation(
	operation,
	{ processEnv, root, runFirebase, runFunctions, runProcess },
) {
	if (operation.type === "firebase") {
		return runFirebase(operation.args, {
			processEnv: { ...processEnv, ...operation.environment },
			root,
		});
	}
	if (operation.type === "functions") {
		return runFunctions(operation.args, { env: processEnv, root });
	}
	return runProcess({
		args: operation.args,
		command: operation.command,
		cwd: root,
		env: { ...processEnv, ...operation.environment },
	});
}

export async function executeTestTask(
	task,
	{
		processEnv = process.env,
		root = repositoryRoot,
		runFirebase = runFirebaseCli,
		runFunctions = runFunctionsCommand,
		runProcess = runChildProcess,
		stderr = process.stderr,
	} = {},
) {
	for (const operation of task.operations) {
		let exitCode;
		try {
			exitCode = await executeOperation(operation, {
				processEnv,
				root,
				runFirebase,
				runFunctions,
				runProcess,
			});
		} catch (error) {
			stderr.write(`Unable to run ${task.suite}: ${error.message}\n`);
			return 1;
		}
		if (exitCode !== 0) {
			return exitCode;
		}
	}
	return 0;
}

export async function runTestTask(
	argv,
	{
		stdout = process.stdout,
		stderr = process.stderr,
		...executionOptions
	} = {},
) {
	let task;
	try {
		task = resolveTestTask(argv);
	} catch (error) {
		stderr.write(`${error.message}\n\n${formatTestTaskHelp()}\n`);
		return 2;
	}
	if (task.help) {
		stdout.write(`${formatTestTaskHelp()}\n`);
		return 0;
	}
	return executeTestTask(task, { stderr, ...executionOptions });
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : "";
if (invokedPath === runnerPath) {
	process.exitCode = await runTestTask(process.argv.slice(2));
}
