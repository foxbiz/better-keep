import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {
	DEPLOY_TARGET_NAMES,
	formatDeployTaskHelp,
	parseDeployTaskArguments,
	resolveDeployTask,
	runDeployTask,
} from "../../tool/deploy_tasks.mjs";

function cacheControlFor(config, source) {
	return config.hosting.headers
		.find((entry) => entry.source === source)
		?.headers.find((header) => header.key === "Cache-Control")?.value;
}

function assertHostingCachePolicy(config) {
	assert.equal(
		cacheControlFor(config, "**"),
		"no-cache, max-age=0, must-revalidate",
	);
	assert.equal(
		cacheControlFor(config, "/_astro/**"),
		"public, max-age=31536000, immutable",
	);
	assert.equal(
		cacheControlFor(config, "/media/**"),
		"public, max-age=86400",
	);
	assert.ok(
		config.hosting.headers.findIndex((entry) => entry.source === "/media/**") >
			config.hosting.headers.findIndex((entry) => entry.source === "**"),
		"the media cache policy must override the earlier catch-all policy",
	);
}

function assertWelcomeRedirects(config) {
	for (const source of ["/welcome{,/**}", "/welcome.html"]) {
		assert.ok(
			config.hosting.redirects.some(
				(entry) =>
					entry.source === source &&
					entry.destination === "/" &&
					entry.type === 301,
			),
		);
	}
}

test("lists deployment targets and treats an omitted target as help", () => {
	assert.deepEqual(parseDeployTaskArguments([]), {help: true});
	assert.deepEqual(parseDeployTaskArguments(["help"]), {help: true});
	assert.deepEqual(DEPLOY_TARGET_NAMES, [
		"backend",
		"hosting",
		"hosting-preview",
		"indexnow",
	]);
	assert.match(formatDeployTaskHelp(), /npm run deploy <target>/);
});

test("IndexNow submission forwards optional dry-run arguments", () => {
	assert.deepEqual(resolveDeployTask(["indexnow", "--dry-run"]).operations, [
		{
			args: ["scripts/submit_indexnow.mjs", "--dry-run"],
			command: "node",
			type: "process",
		},
	]);
});

test("preserves the scoped backend deployment", () => {
	assert.deepEqual(resolveDeployTask(["backend"]).operations, [
		{
			args: [
				"--",
				"deploy",
				"--config",
				"firebase.deploy.json",
				"--project",
				"better-keep-notes",
				"--only",
				"functions,firestore:better-keep,storage",
			],
			type: "firebase",
		},
	]);
});

test("builds the combined website before deploying only Hosting", () => {
	const operations = resolveDeployTask(["hosting", "--debug"]).operations;
	assert.deepEqual(operations[0], {
		args: [],
		command: "./scripts/build_web.sh",
		type: "process",
	});
	assert.deepEqual(operations[1], {
		args: [
			"--",
			"deploy",
			"--config",
			"firebase.deploy.json",
			"--project",
			"better-keep-notes",
			"--only",
			"hosting",
			"--debug",
		],
		type: "firebase",
	});
});

test("builds the combined website before publishing the isolated preview channel", () => {
	const operations = resolveDeployTask(["hosting-preview", "--debug"]).operations;
	assert.deepEqual(operations[0], {
		args: [],
		command: "./scripts/build_web.sh",
		type: "process",
	});
	assert.deepEqual(operations[1], {
		args: [
			"--",
			"hosting:channel:deploy",
			"ui-overhaul",
			"--expires",
			"7d",
			"--no-authorized-domains",
			"--config",
			"firebase.deploy.json",
			"--project",
			"better-keep-notes",
			"--debug",
		],
		type: "firebase",
	});
});

test("production Hosting serves the combined site with protected app routes", () => {
	const config = JSON.parse(readFileSync("firebase.deploy.json", "utf8"));
	assert.equal(config.hosting.public, "build/web");
	assert.equal(config.hosting.cleanUrls, true);
	assertHostingCachePolicy(config);
	assert.deepEqual(config.hosting.rewrites, [
		{source: "/oauth/start", function: "oauthStart"},
		{source: "/oauth/callback", function: "oauthCallback"},
		{source: "/s/**", destination: "/s/index.html"},
		{source: "/app/**", destination: "/app/index.html"},
	]);
	assert.ok(
		config.hosting.headers.some(
			(entry) =>
				entry.source === "/app/**" &&
				entry.headers.some(
					(header) =>
						header.key === "X-Robots-Tag" &&
						header.value === "noindex, nofollow",
				),
		),
	);
	assertWelcomeRedirects(config);
});

test("the full emulator serves the same combined web artifact", () => {
	const config = JSON.parse(readFileSync("firebase.emulators.json", "utf8"));
	assert.equal(config.hosting.public, "build/web");
	assert.equal(config.hosting.cleanUrls, true);
	assertHostingCachePolicy(config);
	assertWelcomeRedirects(config);
	assert.deepEqual(config.hosting.rewrites, [
		{source: "/oauth/start", function: "oauthStart"},
		{source: "/oauth/callback", function: "oauthCallback"},
		{source: "/s/**", destination: "/s/index.html"},
		{source: "/app/**", destination: "/app/index.html"},
	]);
});

test("unknown deployment targets fail with help", async () => {
	let stderr = "";
	const exitCode = await runDeployTask(["unknown"], {
		stderr: {write: (value) => (stderr += value)},
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Unknown deployment target/);
	assert.match(stderr, /Usage: npm run deploy/);
});

test("Hosting deployment stops when the web build fails", async () => {
	let firebaseCalls = 0;
	const exitCode = await runDeployTask(["hosting"], {
		runFirebase: async () => {
			firebaseCalls += 1;
			return 0;
		},
		runProcess: async () => 9,
	});
	assert.equal(exitCode, 9);
	assert.equal(firebaseCalls, 0);
});

test("backend deployment preserves Firebase exit codes and environment", async () => {
	const calls = [];
	const exitCode = await runDeployTask(["backend"], {
		processEnv: {BASE: "present"},
		runFirebase: async (args, options) => {
			calls.push({args, options});
			return 4;
		},
	});
	assert.equal(exitCode, 4);
	assert.equal(calls[0].options.processEnv.BASE, "present");
});
