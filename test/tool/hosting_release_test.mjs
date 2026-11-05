import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
	stageHostingRelease,
	publishHostingRelease,
	parseHostingArguments,
} from "../../tool/hosting_release.mjs";
import {
	hashHostedFiles,
	readJson,
	copyHostedFile,
	hostingHash,
} from "../../tool/hosting_files.mjs";
import { snapshotHosting } from "../../tool/hosting_live.mjs";

const config = {
	cleanUrls: true,
	rewrites: [
		{
			glob: "/oauth/start",
			function: "oauthStart",
			functionRegion: "us-central1",
		},
		{
			glob: "/pinned/**",
			run: { serviceId: "pinned", region: "us-central1", tag: "keep-this-tag" },
		},
		{ glob: "/app/**", path: "/app/index.html" },
	],
	headers: [{ glob: "**", headers: { "Cache-Control": "no-cache" } }],
};
const put = async (root, name, value) => {
	const file = path.join(root, name);
	await mkdir(path.dirname(file), { recursive: true });
	await writeFile(
		file,
		typeof value === "string" ? value : JSON.stringify(value),
	);
};
async function snapshot(directory, version, source, configuration = config) {
	await mkdir(directory, { recursive: true });
	const hashes = await hashHostedFiles(source);
	for (const name of Object.keys(hashes))
		await copyHostedFile(source, directory, name);
	await put(directory, "snapshot.json", {
		version,
		config: configuration,
		completeSite: true,
		files: Object.entries(hashes).map(([path, hash]) => ({ path, hash })),
	});
}
async function beta(directory, version) {
	const base = `/app/releases/${version}/`;
	await put(directory, "beta-build.json", {
		version,
		base,
		stableBase: `${base}stable/`,
		workerRuntime: "shared-v1",
		storage: "isolated-v1",
	});
	await put(directory, "stable/beta-build.json", {
		version,
		base: `${base}stable/`,
		storage: "stable-v1",
	});
	for (const prefix of ["", "stable/"])
		for (const file of [
			"flutter_bootstrap.js",
			"main.dart.js",
			"sqflite_sw.js",
			"sqlite3.wasm",
		])
			await put(
				directory,
				prefix + file,
				file === "sqflite_sw.js" || file === "sqlite3.wasm"
					? `shared runtime ${file}`
					: `${version} ${prefix}${file}`,
			);
}
async function fixture(fn) {
	const root = await mkdtemp(path.join(os.tmpdir(), "hosting-release-"));
	try {
		const original = path.join(root, "original");
		await put(original, "index.html", "old website");
		await put(original, "_astro/old.js", "old page dependency");
		await put(
			original,
			"app/index.html",
			'<base href="/app/"><script src="flutter_bootstrap.js" async></script>',
		);
		await put(original, "app/main.dart.js", "original stable code");
		await put(
			original,
			"app/flutter_bootstrap.js",
			"original stable bootstrap",
		);
		const baseline = path.join(root, "snapshot");
		await snapshot(baseline, "live-1", original);
		const client = path.join(root, "client");
		await beta(client, "beta-test");
		const website = path.join(root, "website");
		await put(website, "index.html", "new website");
		await fn({ root, baseline, client, website });
	} finally {
		await rm(root, { recursive: true, force: true });
	}
}

test("all five Hosting scopes preserve unrelated files and promotion reuses published builds", () =>
	fixture(async ({ root, baseline, client, website }) => {
		for (const target of ["hosting-web", "hosting-app-beta", "hosting-beta"]) {
			const output = path.join(root, target);
			const report = await stageHostingRelease({
				target,
				snapshot: baseline,
				output,
				beta: client,
				website,
			});
			assert.equal(
				await readFile(path.join(output, "public/index.html"), "utf8"),
				target === "hosting-app-beta" ? "old website" : "new website",
			);
			assert.equal(
				await readFile(path.join(output, "public/app/main.dart.js"), "utf8"),
				"original stable code",
			);
			assert.deepEqual(
				report.config.rewrites.find((r) => r.glob === "/pinned/**"),
				config.rewrites[1],
			);
			if (target === "hosting-web") {
				assert.equal(
					await readFile(path.join(output, "public/app/index.html"), "utf8"),
					'<base href="/app/"><script src="flutter_bootstrap.js" async></script>',
				);
				assert.ok(report.changed.every((p) => !p.startsWith("/app/")));
			} else {
				assert.equal(report.release.status, "beta");
				assert.equal(report.release.sequence, 1);
				assert.equal(report.release.stable, null);
			}
			if (target === "hosting-app-beta") {
				assert.ok(report.changed.every((p) => p.startsWith("/app/")));
				assert.deepEqual(report.config.rewrites, config.rewrites);
			}
		}
		const betaOutput = path.join(root, "hosting-app-beta");
		const betaReport = await readJson(path.join(betaOutput, "release.json"));
		const betaSnapshot = path.join(root, "live-beta");
		await snapshot(
			betaSnapshot,
			"live-2",
			path.join(betaOutput, "public"),
			betaReport.config,
		);
		for (const target of ["hosting-app-prod", "hosting-prod"]) {
			const output = path.join(root, target);
			const report = await stageHostingRelease({
				target,
				snapshot: betaSnapshot,
				output,
				website,
			});
			assert.equal(report.release.status, "promoted");
			assert.equal(report.release.sequence, 2);
			assert.equal(
				report.release.stable.base,
				"/app/releases/beta-test/stable/",
			);
			assert.ok(!report.changed.some((p) => p.startsWith("/app/releases/")));
			if (target === "hosting-app-prod")
				assert.deepEqual(report.changed, ["/app/beta-release.json"]);
			const promotedSnapshot = path.join(root, `${target}-snapshot`);
			await snapshot(
				promotedSnapshot,
				"live-3",
				path.join(output, "public"),
				report.config,
			);
			await assert.rejects(
				stageHostingRelease({
					target,
					snapshot: promotedSnapshot,
					output: `${output}-again`,
					website,
				}),
				/No unpromoted/,
			);
			const next = path.join(root, `next-${target}`);
			await beta(next, "beta-next");
			const nextReport = await stageHostingRelease({
				target: "hosting-app-beta",
				snapshot: promotedSnapshot,
				output: `${output}-next`,
				beta: next,
			});
			assert.deepEqual(nextReport.release.stable, report.release.stable);
			assert.equal(nextReport.release.sequence, 3);
		}
		const incompatible = path.join(root, "incompatible-client");
		await beta(incompatible, "beta-incompatible");
		await put(incompatible, "sqflite_sw.js", "changed database runtime");
		await assert.rejects(
			stageHostingRelease({
				target: "hosting-app-beta",
				snapshot: betaSnapshot,
				output: path.join(root, "incompatible-output"),
				beta: incompatible,
			}),
			/runtime changed/,
		);

		await assert.rejects(
			stageHostingRelease({
				target: "hosting-app-beta",
				snapshot: betaSnapshot,
				output: path.join(root, "reused"),
				beta: client,
			}),
			/already published/,
		);
	}));

test("unsafe or incomplete preparation fails without publishing", () =>
	fixture(async ({ root, baseline, client, website }) => {
		assert.throws(
			() => parseHostingArguments("hosting-web", ["--config", "anything"]),
			/only/,
		);
		await assert.rejects(
			stageHostingRelease({
				target: "hosting-app-prod",
				snapshot: baseline,
				output: path.join(root, "no-beta"),
			}),
			/paired stable build/,
		);
		await assert.rejects(
			stageHostingRelease({
				target: "hosting-web",
				snapshot: baseline,
				output: path.join(baseline, "nested"),
				website,
			}),
			/separate/,
		);
		await put(website, "app/index.html", "unwanted app");
		await assert.rejects(
			stageHostingRelease({
				target: "hosting-web",
				snapshot: baseline,
				output: path.join(root, "bad-website"),
				website,
			}),
			/must not contain/,
		);
		await put(client, "stable/beta-build.json", { version: "other" });
		await assert.rejects(
			stageHostingRelease({
				target: "hosting-app-beta",
				snapshot: baseline,
				output: path.join(root, "mismatch"),
				beta: client,
			}),
			/does not match/,
		);
		await put(baseline, "app/main.dart.js", "modified");
		await assert.rejects(
			stageHostingRelease({
				target: "hosting-app-beta",
				snapshot: baseline,
				output: path.join(root, "tampered"),
				beta: client,
			}),
			/Snapshot was modified/,
		);
	}));

test("publishing is Hosting-only and fails closed on artifact changes, upload failure or a concurrent release", () =>
	fixture(async ({ root, baseline, client }) => {
		const output = path.join(root, "prepared");
		const report = await stageHostingRelease({
			target: "hosting-app-beta",
			snapshot: baseline,
			output,
			beta: client,
		});
		for (const mode of [
			"success",
			"stale",
			"concurrent",
			"upload-failed",
			"config-lost",
			"not-finalized",
		]) {
			const calls = [];
			let liveCalls = 0;
			const api = {
				live: async () => ({
					name:
						mode === "stale" || (mode === "concurrent" && liveCalls++ > 0)
							? "live-other"
							: "live-1",
				}),
				create: async () => {
					calls.push("create");
					return "new-version";
				},
				upload: async () => {
					calls.push("upload");
					if (mode === "upload-failed") throw new Error("Upload failed");
				},
				finalize: async (_, config) => {
					assert.deepEqual(config, report.config);
					calls.push("finalize");
				},
				version: async () => ({
					status: mode === "not-finalized" ? "CREATED" : "FINALIZED",
					config: mode === "config-lost" ? {} : report.config,
				}),
				release: async () => calls.push("release"),
			};
			if (mode === "success") {
				await publishHostingRelease(output, "hosting-app-beta", api);
				assert.deepEqual(calls, ["create", "upload", "finalize", "release"]);
			} else {
				await assert.rejects(
					publishHostingRelease(output, "hosting-app-beta", api),
					/changed|Upload failed|release blocked/,
				);
				assert.ok(!calls.includes("release"));
				if (mode === "stale") assert.deepEqual(calls, []);
			}
		}
		await assert.rejects(
			publishHostingRelease(output, "hosting-web", {}),
			/target mismatch/,
		);
		await put(output, "public/app/main.dart.js", "modified");
		await assert.rejects(
			publishHostingRelease(output, "hosting-app-beta", {}),
			/were modified/,
		);
	}));

test("complete snapshots retain live configuration and reject drift or hash mismatches", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "hosting-snapshot-"));
	try {
		const data = {
			"/app/index.html": "app",
			"/index.html": "website",
			"/__assets/icon.svg": "ordinary site asset",
			"/__/firebase/init.js": "listed script",
			"/__/firebase/init.json": "listed config",
		};
		for (const mode of ["success", "drift", "mismatch"]) {
			let calls = 0;
			const directory = path.join(root, mode);
			const options = {
				api: {
					live: async () => ({
						name: mode === "drift" && calls++ > 0 ? "other" : "live-1",
						config,
					}),
					files: async () =>
						Object.entries(data).map(([path, data]) => ({
							path,
							hash: hostingHash(data),
						})),
				},
				fetchFile: async (url) => {
					assert.ok(!url.pathname.startsWith("/__/"));
					return new Response(
						mode === "mismatch" ? "wrong" : data[url.pathname],
					);
				},
			};
			if (mode === "success") {
				await snapshotHosting(directory, options);
				const manifest = await readJson(path.join(directory, "snapshot.json"));
				assert.equal(manifest.completeSite, true);
				assert.deepEqual(manifest.config, config);
				assert.deepEqual(
					manifest.files.map((f) => f.path).sort(),
					["/__assets/icon.svg", "/app/index.html", "/index.html"],
				);
			} else {
				await assert.rejects(
					snapshotHosting(directory, options),
					/differs|changed/,
				);
				await assert.rejects(
					readFile(path.join(directory, "snapshot.json")),
					/ENOENT/,
				);
			}
		}
	} finally {
		await rm(root, { recursive: true, force: true });
	}
});

test("website callback policy replaces legacy scope while preserving app policy", () =>
	fixture(async ({ root, baseline, website }) => {
		const stored = await readJson(path.join(baseline, "snapshot.json"));
		stored.config.headers.push({
			glob: "/{oauth/storage/callback,app/storage-auth.html,storage-auth.html}",
			headers: {
				"Content-Security-Policy": "old hash",
				"Referrer-Policy": "no-referrer",
			},
		});
		await put(baseline, "snapshot.json", stored);
		const report = await stageHostingRelease({
			target: "hosting-web",
			snapshot: baseline,
			output: path.join(root, "callback"),
			website,
		});
		assert.equal(
			report.config.headers.find((h) => h.glob === "/app/storage-auth.html")
				.headers["Content-Security-Policy"],
			"old hash",
		);
		assert.equal(
			report.config.headers.filter((h) =>
				h.glob.includes("oauth/storage/callback"),
			).length,
			1,
		);
		const current = report.config.headers.find((h) =>
			h.glob.includes("oauth/storage/callback"),
		);
		assert.match(current.headers["Content-Security-Policy"], /sha256-/);
		assert.equal(current.headers["Referrer-Policy"], "no-referrer");
	}));
