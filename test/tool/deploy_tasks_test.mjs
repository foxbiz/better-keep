import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
	DEPLOY_TARGET_NAMES,
	formatDeployTaskHelp,
	parseDeployTaskArguments,
	resolveDeployTask,
	runDeployTask,
} from "../../tool/deploy_tasks.mjs";

function cacheControlFor(hosting, source) {
	return hosting.headers
		.find((entry) => entry.source === source)
		?.headers.find((header) => header.key === "Cache-Control")?.value;
}

function assertHostingCachePolicy(hosting) {
	assert.equal(
		cacheControlFor(hosting, "**"),
		"no-cache, max-age=0, must-revalidate",
	);
	assert.equal(
		cacheControlFor(hosting, "/_astro/**"),
		"public, max-age=31536000, immutable",
	);
	assert.equal(cacheControlFor(hosting, "/media/**"), "public, max-age=86400");
	assert.ok(
		hosting.headers.findIndex((entry) => entry.source === "/media/**") >
			hosting.headers.findIndex((entry) => entry.source === "**"),
		"the media cache policy must override the earlier catch-all policy",
	);
}

function assertWelcomeRedirects(hosting) {
	for (const source of ["/welcome{,/**}", "/welcome.html"]) {
		assert.ok(
			hosting.redirects.some(
				(entry) =>
					entry.source === source &&
					entry.destination === "/" &&
					entry.type === 301,
			),
		);
	}
}

function headerValue(hosting, key) {
	return hosting.headers
		.find((entry) => entry.source === "**")
		?.headers.find((header) => header.key === key)?.value;
}

test("lists deployment targets and treats an omitted target as help", () => {
	assert.deepEqual(parseDeployTaskArguments([]), { help: true });
	assert.deepEqual(parseDeployTaskArguments(["help"]), { help: true });
	assert.deepEqual(DEPLOY_TARGET_NAMES, [
		"backend",
		"hosting-admin",
		"hosting-app-beta",
		"hosting-app-prod",
		"hosting-beta",
		"hosting-prod",
		"hosting-web",
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

test("Hosting commands use the scoped release runner and reject unsafe overrides", () => {
	for (const target of DEPLOY_TARGET_NAMES.filter(
		(name) => name.startsWith("hosting-") && name !== "hosting-admin",
	)) {
		assert.deepEqual(resolveDeployTask([target, "--prepare-only"]).operations, [
			{
				args: ["tool/hosting_release.mjs", target, "--prepare-only"],
				command: "node",
				type: "process",
			},
		]);
		assert.throws(
			() => resolveDeployTask([target, "--only", "functions"]),
			/Hosting accepts only/,
		);
	}
	for (const old of ["hosting", "hosting-public", "hosting-admin-preview"])
		assert.throws(() => resolveDeployTask([old]), /Unknown deployment target/);
});

test("production Hosting isolates public and administrator artifacts", () => {
	const config = JSON.parse(readFileSync("firebase.deploy.json", "utf8"));
	const publicHosting = config.hosting.find(
		(hosting) => hosting.target === "public",
	);
	const adminHosting = config.hosting.find(
		(hosting) => hosting.target === "admin",
	);
	assert.equal(publicHosting.public, "build/web");
	assert.equal(adminHosting.public, "build/admin");
	assertHostingCachePolicy(publicHosting);
	assert.deepEqual(publicHosting.rewrites, [
		{ source: "/oauth/storage/start", function: "storageOAuthStart" },
		{
			source: "/oauth/storage/callback",
			destination: "/app/storage-auth.html",
		},
		{ source: "/oauth/start", function: "oauthStart" },
		{ source: "/oauth/apple", function: "desktopAppleAuth" },
		{ source: "/oauth/callback", function: "oauthCallback" },
		{ source: "/s/**", destination: "/s/index.html" },
		{ source: "/app/**", destination: "/app/index.html" },
	]);
	assert.ok(
		publicHosting.headers.some(
			(entry) =>
				entry.source === "/app/**" &&
				entry.headers.some(
					(header) =>
						header.key === "X-Robots-Tag" &&
						header.value === "noindex, nofollow",
				),
		),
	);
	assertWelcomeRedirects(publicHosting);
	assert.equal(headerValue(adminHosting, "Cache-Control"), "no-store");
	assert.equal(
		headerValue(adminHosting, "X-Robots-Tag"),
		"noindex, nofollow, noarchive",
	);
	assert.equal(headerValue(adminHosting, "Referrer-Policy"), "no-referrer");
	assert.match(
		headerValue(adminHosting, "Content-Security-Policy"),
		/default-src 'none'/,
	);
	assert.match(
		headerValue(adminHosting, "Content-Security-Policy"),
		/connect-src[^;]*https:\/\/content-firebaseappcheck\.googleapis\.com/,
	);
	assert.doesNotMatch(
		headerValue(adminHosting, "Content-Security-Policy"),
		/unsafe-inline/,
	);
});

test("the full emulator serves the same combined web artifact", () => {
	const config = JSON.parse(readFileSync("firebase.emulators.json", "utf8"));
	assert.equal(config.hosting.public, "build/web");
	assert.equal(config.hosting.cleanUrls, true);
	assertHostingCachePolicy(config.hosting);
	assertWelcomeRedirects(config.hosting);
	assert.deepEqual(config.hosting.rewrites, [
		{ source: "/oauth/storage/start", function: "storageOAuthStart" },
		{
			source: "/oauth/storage/callback",
			destination: "/app/storage-auth.html",
		},
		{ source: "/oauth/start", function: "oauthStart" },
		{ source: "/oauth/callback", function: "oauthCallback" },
		{ source: "/s/**", destination: "/s/index.html" },
		{ source: "/app/**", destination: "/app/index.html" },
	]);
});

test("unknown deployment targets fail with help", async () => {
	let stderr = "";
	const exitCode = await runDeployTask(["unknown"], {
		stderr: { write: (value) => (stderr += value) },
	});
	assert.equal(exitCode, 2);
	assert.match(stderr, /Unknown deployment target/);
	assert.match(stderr, /Usage: npm run deploy/);
});

test("Hosting deployment stops when the web build fails", async () => {
	let firebaseCalls = 0;
	const exitCode = await runDeployTask(["hosting-beta"], {
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
		processEnv: { BASE: "present" },
		runFirebase: async (args, options) => {
			calls.push({ args, options });
			return 4;
		},
	});
	assert.equal(exitCode, 4);
	assert.equal(calls[0].options.processEnv.BASE, "present");
});

test("admin deployment validates its bundle and cannot change scope", () => {
	const steps = resolveDeployTask(["hosting-admin"]).operations;
	assert.deepEqual(
		steps.map((s) => s.type),
		["process", "process", "firebase", "process"],
	);
	assert.deepEqual(steps[0].args, [
		"--prefix",
		"admin-site",
		"run",
		"build",
		"--",
		"--outDir",
		"../build/admin",
	]);
	assert.deepEqual(steps[3].args, ["scripts/verify_admin_deployment.mjs"]);
	assert.deepEqual(steps[1].args, [
		"scripts/validate_admin_bundle.mjs",
		"build/admin",
	]);
	assert.equal(steps[2].args.at(-1), "hosting:admin");
	assert.throws(
		() => resolveDeployTask(["hosting-admin", "--only", "functions"]),
		/no overrides/,
	);
});
