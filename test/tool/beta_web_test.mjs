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

function assertLoaderPaths(bootstrap, basePath) {
	let configAtLoad;
	const context = {
		URL,
		document: { baseURI: "https://preview.example/app/" },
		_flutter: {
			loader: {
				load({ config }) {
					configAtLoad = config;
				},
			},
		},
	};
	context.window = context;
	runInNewContext(bootstrap, context);
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
		await writeFile(
			path.join(beta, "flutter_bootstrap.js"),
			"window._flutter = window._flutter || {};\n_flutter.loader.load({serviceWorkerSettings:{}});",
		);
		await writeFile(path.join(beta, "manifest.json"), "{}");
		await finalizeBetaBuild(beta, "beta-test");
		const bootstrap = await readFile(
			path.join(beta, "flutter_bootstrap.js"),
			"utf8",
		);
		assertLoaderPaths(bootstrap, "/app/releases/beta-test/");
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
				await mkdir(output, { recursive: true });
				await writeFile(
					path.join(output, "flutter_bootstrap.js"),
					"window._flutter=window._flutter || {};\n_flutter.loader.load({});",
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
			assertLoaderPaths(bootstrap, basePath);
		}
		assert.equal(beta.storage, "isolated-v1");
		assert.equal(stable.storage, "stable-v1");
		assert.equal(beta.stableBase, stable.base);
		assert.notEqual(beta.base, stable.base);
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});
