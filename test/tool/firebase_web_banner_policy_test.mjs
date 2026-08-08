import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {dirname, join} from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {resolveTestTask} from "../../tool/test_tasks.mjs";

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const mainWebShell = readFileSync(join(repositoryRoot, "web", "index.html"), "utf8");
const resetPasswordPage = readFileSync(
	join(repositoryRoot, "web", "reset-password.html"),
	"utf8",
);
const sharedNoteLayout = readFileSync(
	join(repositoryRoot, "site", "src", "layouts", "ShareLayout.astro"),
	"utf8",
);
const browserRunner = readFileSync(
	join(repositoryRoot, "tool", "run_flutter_web_integration.mjs"),
	"utf8",
);
const buildReleaseWorkflow = readFileSync(
	join(repositoryRoot, ".github", "workflows", "build-release.yml"),
	"utf8",
);

function assertWorkflowProvisionsMatchedBrowser({
	name,
	source,
	acceptanceCommand,
}) {
	const setupIndex = source.indexOf("uses: browser-actions/setup-chrome@v2");
	const commandIndex = source.indexOf(acceptanceCommand);
	const chromePathIndex = source.indexOf(
		"CHROME_BINARY: ${{ steps.setup-chrome.outputs.chrome-path }}",
	);
	const driverPathIndex = source.indexOf(
		"CHROMEDRIVER_BINARY: ${{ steps.setup-chrome.outputs.chromedriver-path }}",
	);

	assert.notEqual(setupIndex, -1, `${name} must install Chrome and ChromeDriver`);
	assert.match(source, /install-chromedriver:\s*true/);
	assert.notEqual(commandIndex, -1, `${name} must run ${acceptanceCommand}`);
	assert.ok(setupIndex < commandIndex, `${name} must install Chrome first`);
	assert.ok(
		chromePathIndex > setupIndex && chromePathIndex < commandIndex,
		`${name} must pass the installed Chrome path to the acceptance step`,
	);
	assert.ok(
		driverPathIndex > setupIndex && driverPathIndex < commandIndex,
		`${name} must pass the installed ChromeDriver path to the acceptance step`,
	);
}

test("main Flutter shell hides only Firebase Auth's redundant emulator warning", () => {
	const warningRule = mainWebShell.match(
		/\.firebase-emulator-warning\s*\{(?<declarations>[^}]*)\}/,
	);

	assert.ok(warningRule, "web/index.html must target Firebase's warning class");
	assert.equal(
		warningRule.groups.declarations.replaceAll(/\s+/g, " ").trim(),
		"display: none !important;",
	);
	assert.match(
		mainWebShell,
		/FirebaseEnvironmentBanner is the authoritative cross-platform status/,
	);
	assert.doesNotMatch(
		mainWebShell,
		/(?:^|[},])\s*(?:p|body\s*>\s*p|\[class\*=["']firebase["']\])\s*\{[^}]*display:\s*none/im,
	);
});

test("standalone Firebase web pages retain the SDK warning", () => {
	for (const [name, source] of [
		["reset-password", resetPasswordPage],
		["shared-note", sharedNoteLayout],
	]) {
		assert.doesNotMatch(
			source,
			/\.firebase-emulator-warning\s*\{/,
			`${name} must not inherit the Flutter app's warning suppression`,
		);
	}
});

test("web environment acceptance uses a bounded full-shell browser run", () => {
	const task = resolveTestTask(["firebase-environment-web"]);
	assert.deepEqual(task.operations.at(-1), {
		args: ["tool/run_flutter_web_integration.mjs"],
		command: "node",
		environment: {},
		type: "process",
	});
	assert.doesNotMatch(
		JSON.stringify(task.operations),
		/flutter test --platform chrome/,
	);

	assert.match(browserRunner, /"-d",\s*"web-server"/);
	assert.match(browserRunner, /"--web-hostname=127\.0\.0\.1"/);
	assert.match(browserRunner, /--driver-port=/);
	assert.match(browserRunner, /FLUTTER_WEB_INTEGRATION_TIMEOUT_MS/);
	assert.match(browserRunner, /terminateChild\(chromeDriver\)/);
	assert.match(browserRunner, /SIGTERM/);
	assert.match(browserRunner, /SIGKILL/);
});

test("the release gate provisions a matched browser before web acceptance", () => {
	assertWorkflowProvisionsMatchedBrowser({
		name: "release gate",
		source: buildReleaseWorkflow,
		acceptanceCommand: "npm run release",
	});
});
