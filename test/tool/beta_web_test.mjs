import assert from "node:assert/strict";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import { mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import {
	stageBeta,
	finalizeBetaBuild,
	buildBetaRelease,
} from "../../tool/beta_web.mjs";

import { prepareOfflineAssets } from "../../tool/prepare_offline_assets.mjs";

const bootstrapTemplate = (
	await readFile(
		new URL("../../web/flutter_bootstrap.js", import.meta.url),
		"utf8",
	)
)
	.replace("{{flutter_js}}", "")
	.replace("{{flutter_build_config}}", "");
async function assertLoaderPaths(bootstrap, basePath) {
	let configAtLoad;
	const context = {
		URL,
		document: {
			currentScript: {
				src: new URL(
					"flutter_bootstrap.js",
					"https://preview.example" + basePath,
				).href,
			},
			baseURI: "https://preview.example/app/",
		},
		navigator: {},
		setTimeout: () => {},
		_flutter: {
			buildConfig: { builds: [{ compileTarget: "dart2js" }] },
			loader: {
				load({ config }) {
					configAtLoad = config;
				},
			},
		},
	};
	context.window = context;
	await runInNewContext(bootstrap, context);
	await new Promise((resolve) => setImmediate(resolve));
	const expected = new URL(basePath, context.document.baseURI).href;
	assert.equal(configAtLoad.assetBase, expected);
	assert.equal(configAtLoad.entrypointBaseUrl, expected);
	assert.equal(configAtLoad.canvasKitBaseUrl, expected + "canvaskit/");
	assert.equal(
		new URL("version.json", configAtLoad.assetBase).href,
		expected + "version.json",
	);
}

test("staging preserves deployed bytes and refuses modified baselines or unsafe builds", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "beta-stage-"));
	try {
		const snapshot = path.join(root, "snapshot");
		const beta = path.join(root, "beta");
		await mkdir(path.join(snapshot, "app"), { recursive: true });
		await mkdir(beta);
		const files = {
			"/app/index.html":
				'<base href="/app/"><script src="flutter_bootstrap.js" async></script>',
			"/app/main.dart.js": "unchanged stable code",
			"/app/flutter_bootstrap.js": "unchanged stable bootstrap",
		};
		for (const [name, data] of Object.entries(files))
			await writeFile(path.join(snapshot, name), data);
		await writeFile(
			path.join(snapshot, "snapshot.json"),
			JSON.stringify({
				version: "test-version",
				files: Object.entries(files).map(([name, data]) => ({
					path: name,
					hash: createHash("sha256")
						.update(gzipSync(data, { level: 9 }))
						.digest("hex"),
				})),
			}),
		);
		await writeFile(path.join(beta, "flutter_bootstrap.js"), bootstrapTemplate);
		await writeFile(path.join(beta, "manifest.json"), "{}");
		await finalizeBetaBuild(beta, "beta-test");
		const bootstrap = await readFile(
			path.join(beta, "flutter_bootstrap.js"),
			"utf8",
		);
		await assertLoaderPaths(bootstrap, "/app/releases/beta-test/");
		assert.ok(!bootstrap.includes("serviceWorkerSettings"));
		const output = path.join(root, "output");
		const report = await stageBeta({ snapshot, beta, output });
		assert.equal(report.stableFilesPreserved, 2);
		assert.equal(
			await readFile(path.join(output, "app/main.dart.js"), "utf8"),
			files["/app/main.dart.js"],
		);
		assert.ok(
			(await readFile(path.join(output, "app/index.html"), "utf8")).includes(
				"/app/beta-launcher.js",
			),
		);
		const website = path.join(root, "website");
		await mkdir(website);
		await writeFile(path.join(website, "index.html"), "new website");
		const combined = path.join(root, "combined");
		await stageBeta({ snapshot, beta, output: combined, website });
		const config = JSON.parse(
			await readFile(`${combined}-firebase.json`, "utf8"),
		);
		assert.deepEqual(Object.keys(config), ["hosting"]);
		assert.equal(config.hosting.site, "better-keep-notes");
		assert.equal(config.hosting.target, undefined);
		assert.equal(
			config.hosting.rewrites.find(
				(r) => r.source === "/oauth/storage/callback",
			).destination,
			"/storage-auth.html",
		);
		assert.equal(
			await readFile(path.join(combined, "index.html"), "utf8"),
			"new website",
		);
		assert.equal(
			await readFile(path.join(combined, "app/main.dart.js"), "utf8"),
			files["/app/main.dart.js"],
		);
		await assert.rejects(
			stageBeta({ snapshot, beta, output }),
			/already exists/,
		);
		await assert.rejects(
			stageBeta({ snapshot, beta, output: path.join(snapshot, "nested") }),
			/separate/,
		);
		await assert.rejects(finalizeBetaBuild(beta, "../escape"), /release ID/);
		await writeFile(path.join(snapshot, "app/main.dart.js"), "different build");
		await assert.rejects(
			stageBeta({ snapshot, beta, output: path.join(root, "other") }),
			/Snapshot was modified/,
		);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("paired build uses distinct compile-time storage modes and compiles both workers", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "beta-pair-"));
	const builds = [],
		workers = [];
	try {
		await buildBetaRelease("pair-test", root, {
			runBuild: async (command, args) => {
				builds.push({ command, args });
				if (command !== "flutter") return;
				const output = args.find((a) => a.startsWith("--output=")).slice(9);
				await mkdir(path.join(output, "assets"), { recursive: true });
				await writeFile(path.join(output, "assets/icon.png"), "fixture");
				await writeFile(
					path.join(output, "offline_worker.js"),
					"const bundledAssets = [];",
				);
				await writeFile(
					path.join(output, "flutter_bootstrap.js"),
					bootstrapTemplate,
				);
				await writeFile(path.join(output, "manifest.json"), "{}");
			},
			compileWorker: async (output) => workers.push(output),
		});
		assert.equal(builds[0].command, "node"); // compatibility check precedes either build
		assert.ok(builds[1].args.includes("--dart-define=WEB_BETA=true"));
		assert.ok(builds[2].args.includes("--dart-define=WEB_BETA=false"));
		assert.deepEqual(workers, [root, path.join(root, "stable")]);
		const beta = JSON.parse(await readFile(path.join(root, "beta-build.json")));
		const stable = JSON.parse(
			await readFile(path.join(root, "stable/beta-build.json")),
		);
		for (const [directory, basePath] of [
			[root, "/app/releases/pair-test/"],
			[path.join(root, "stable"), "/app/releases/pair-test/stable/"],
		]) {
			const bootstrap = await readFile(
				path.join(directory, "flutter_bootstrap.js"),
				"utf8",
			);
			assert.match(
				await readFile(path.join(directory, "offline_worker.js"), "utf8"),
				/assets\/icon\.png/,
			);
			await writeFile(path.join(directory, "assets/added.txt"), "new");
			await prepareOfflineAssets(directory);
			assert.match(
				await readFile(path.join(directory, "offline_worker.js"), "utf8"),
				/assets\/added\.txt/,
			);
			await assertLoaderPaths(bootstrap, basePath);
		}
		assert.equal(beta.storage, "isolated-v1");
		assert.equal(stable.storage, "stable-v1");
		assert.equal(beta.stableBase, stable.base);
		assert.notEqual(beta.base, stable.base);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("first frame during a channel switch warms the matching controller", async () => {
	const base = "https://preview.example/app/releases/qa/";
	const workers = new EventTarget();
	const window = new EventTarget();
	const sent = [];
	const worker = (path) => ({
		scriptURL: new URL(path, base).href,
		postMessage: (message) => sent.push([path, message.base]),
	});
	workers.controller = worker("/app/offline_worker.js");
	workers.register = async () => ({active: workers.controller});
	workers.ready = workers.register();
	runInNewContext(bootstrapTemplate, {
		window, document: {currentScript: {src: base + "flutter_bootstrap.js"}},
		navigator: {serviceWorker: workers}, URL,
		performance: {getEntriesByType: () => []}, setTimeout: () => {},
		_flutter: {buildConfig: {builds: [{compileTarget: "dart2js"}]}, loader: {load() {}}},
	});
	window.dispatchEvent(new Event("flutter-first-frame"));
	await Promise.resolve();
	assert.deepEqual(sent, []);
	workers.controller = worker("offline_worker.js");
	workers.dispatchEvent(new Event("controllerchange"));
	workers.dispatchEvent(new Event("controllerchange"));
	assert.deepEqual(sent, [["offline_worker.js", base]]);
});

test("offline worker only handles public resources and normalizes version cache busting", async () => {
	const listeners = new Map();
	const origin = "https://preview.example";
	const lookups = [];
	const context = {
		URL,
		self: {
			registration: { scope: origin + "/app" },
			location: { href: origin + "/app/offline_worker.js" },
			navigator: { onLine: false },
			addEventListener: (name, handler) => listeners.set(name, handler),
		},
		caches: {
			open: async () => ({
				match: async (key) => {
					lookups.push(key);
					return new Response("cached");
				},
			}),
		},
	};
	runInNewContext(
		await readFile(
			new URL("../../web/offline_worker.js", import.meta.url),
			"utf8",
		),
		context,
	);
	const handle = (url, options) => {
		let response;
		listeners.get("fetch")({
			request: new Request(url, options),
			respondWith: (value) => {
				response = value;
			},
		});
		return response;
	};
	for (const url of [
		"/oauth/storage/callback",
		"/app/storage-auth.html",
		"/__emulator/auth",
		"/app/main.dart.js?code=secret",
	]) {
		assert.equal(handle(origin + url), undefined);
	}
	assert.equal(
		handle(origin + "/app/main.dart.js", {
			headers: { Authorization: "Bearer synthetic" },
		}),
		undefined,
	);
	assert.equal(
		handle(origin + "/app/main.dart.js", { method: "POST" }),
		undefined,
	);
	assert.equal(handle("https://example.org/app/main.dart.js"), undefined);
	assert.equal(
		await (await handle(origin + "/app/version.json?cachebuster=123")).text(),
		"cached",
	);
	assert.deepEqual(lookups, [origin + "/app/version.json"]);
});
