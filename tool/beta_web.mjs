#!/usr/bin/env node
import { prepareOfflineAssets } from "./prepare_offline_assets.mjs";
import { readFile, writeFile, mkdir, cp, access, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";

const repository = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
);
function releaseBase(version) {
	if (!/^[a-z0-9-]{1,80}$/.test(version))
		throw new Error(
			"Use a lowercase release ID containing letters, numbers and hyphens",
		);
	return `/app/releases/${version}/`;
}
function run(command, args) {
	const result = spawnSync(command, args, {
		cwd: repository,
		stdio: "inherit",
	});
	if (result.error) throw result.error;
	if (result.status !== 0)
		throw new Error(`${command} failed (${result.status})`);
}
export async function compileBetaWorker(directory) {
	// The checked-in worker predates setWebOptions. Compile the worker matching
	// the resolved dependency so indexedDbName is actually honored in browsers.
	const packagesFile = path.join(repository, ".dart_tool/package_config.json");
	const packages = JSON.parse(await readFile(packagesFile, "utf8"));
	const dependency = packages.packages.find(
		(p) => p.name === "sqflite_common_ffi_web",
	);
	if (!dependency) throw new Error("Run flutter pub get first");
	const packageRoot = new URL(
		`${dependency.rootUri.replace(/\/$/, "")}/`,
		pathToFileURL(packagesFile),
	);
	const entrypoint = fileURLToPath(new URL("web/sqflite_sw.dart", packageRoot));
	run("dart", [
		"compile",
		"js",
		"-O4",
		`--packages=${packagesFile}`,
		"-o",
		path.join(directory, "sqflite_sw.js"),
		entrypoint,
	]);
	await Promise.all(
		[".deps", ".map"].map((suffix) =>
			rm(path.join(directory, `sqflite_sw.js${suffix}`), { force: true }),
		),
	);
}
export async function finalizeBetaBuild(
	directory,
	version,
	{ stable = false } = {},
) {
	const base = releaseBase(version) + (stable ? "stable/" : "");
	const bootstrapFile = path.join(directory, "flutter_bootstrap.js");
	const source = await readFile(bootstrapFile, "utf8");
	if (
		!source.includes('new URL("./", document.currentScript.src)') ||
		!source.includes('new URL("offline_worker.js", runtime)')
	) {
		throw new Error("Unrecognized Flutter bootstrap; cannot verify offline release paths");
	}
	const manifestFile = path.join(directory, "manifest.json");
	const manifest = JSON.parse(await readFile(manifestFile, "utf8"));
	Object.assign(manifest, {
		name: stable ? "Better Keep" : "Better Keep Beta",
		short_name: stable ? "Keep" : "Keep Beta",
		start_url: "/app/",
		scope: "/app/",
	});
	await writeFile(manifestFile, JSON.stringify(manifest, null, 2));
	await writeFile(
		path.join(directory, "beta-build.json"),
		JSON.stringify({
			version,
			base,
			storage: stable ? "stable-v1" : "isolated-v1",
		}),
	);
}

// Fixed worker URLs keep concurrent releases on one writer per beta database.
export async function stageBetaRuntime(beta, output) {
	for (const name of ["sqflite_sw.js", "sqlite3.wasm"]) {
		const bytes = await readFile(path.join(beta, name));
		const target = path.join(output, "app/beta-runtime/v1", name);
		let existing;
		try {
			existing = await readFile(target);
		} catch (error) {
			if (error.code !== "ENOENT") throw error;
		}
		if (existing && !existing.equals(bytes))
			throw new Error(
				"Beta database runtime changed; review storage compatibility before publishing",
			);
		if (!existing) {
			await mkdir(path.dirname(target), { recursive: true });
			await writeFile(target, bytes);
		}
	}
}

export async function stageBeta({
	snapshot,
	beta,
	output,
	website,
	launcher = path.join(repository, "web/js/beta_launcher.js"),
}) {
	snapshot = path.resolve(snapshot);
	beta = path.resolve(beta);
	output = path.resolve(output);
	// Never overwrite an existing bundle or accidentally copy a directory into itself.
	for (const source of [snapshot, beta]) {
		if (
			output === source ||
			output.startsWith(`${source}${path.sep}`) ||
			source.startsWith(`${output}${path.sep}`)
		) {
			throw new Error("Output must be separate from its inputs");
		}
	}
	try {
		await access(output);
		throw new Error("Output already exists; use a new directory");
	} catch (error) {
		if (error.code !== "ENOENT") throw error;
	}
	const baseline = JSON.parse(
		await readFile(path.join(snapshot, "snapshot.json"), "utf8"),
	);
	const release = JSON.parse(
		await readFile(path.join(beta, "beta-build.json"), "utf8"),
	);
	if (
		release.storage !== "isolated-v1" ||
		release.base !== releaseBase(release.version)
	)
		throw new Error("Beta build metadata is invalid");
	if (!baseline.files.some((f) => f.path === "/app/index.html"))
		throw new Error("Baseline has no app index");
	for (const file of baseline.files) {
		const target = path.resolve(snapshot, `.${file.path}`);
		if (
			!file.path.startsWith("/app/") ||
			!target.startsWith(`${snapshot}${path.sep}`)
		)
			throw new Error("Invalid snapshot file path");
		const bytes = await readFile(target);
		if (
			createHash("sha256")
				.update(gzipSync(bytes, { level: 9 }))
				.digest("hex") !== file.hash
		) {
			throw new Error(`Snapshot was modified: ${file.path}`);
		}
	}
	const stableIndex = await readFile(
		path.join(snapshot, "app/index.html"),
		"utf8",
	);
	const entry =
		/<script\s+src=["']flutter_bootstrap\.js["']\s+async><\/script>/g;
	if ([...stableIndex.matchAll(entry)].length !== 1)
		throw new Error("Unrecognized stable bootstrap tag");
	await mkdir(output, { recursive: true });
	if (website) {
		await cp(path.resolve(website), output, { recursive: true });
		for (const page of [
			"auth",
			"reset-password",
			"desktop-checkout",
			"storage-auth",
		]) {
			await cp(
				path.join(repository, "web", `${page}.html`),
				path.join(output, `${page}.html`),
			);
		}
		for (const folder of ["icons", ".well-known", "js"]) {
			await cp(
				path.join(repository, "web", folder),
				path.join(output, folder),
				{ recursive: true },
			);
		}
		await rm(path.join(output, "js/firebase_emulator_proxy.js"), {
			force: true,
		});
	}
	await cp(path.join(snapshot, "app"), path.join(output, "app"), {
		recursive: true,
	});
	await cp(beta, path.join(output, release.base.slice(1)), { recursive: true });
	if (release.stableBase) await stageBetaRuntime(beta, output);
	await cp(launcher, path.join(output, "app/beta-launcher.js"));
	await writeFile(
		path.join(output, "app/index.html"),
		stableIndex.replace(
			entry,
			'<script src="/app/beta-launcher.js" defer></script>',
		),
	);
	await writeFile(
		path.join(output, "app/beta-release.json"),
		JSON.stringify(release),
	);
	// Stable JS, database worker, encryption configuration and other assets stay byte-identical.
	for (const file of baseline.files.filter(
		(f) => f.path !== "/app/index.html",
	)) {
		const [before, after] = await Promise.all([
			readFile(path.join(snapshot, file.path)),
			readFile(path.join(output, file.path)),
		]);
		if (!before.equals(after))
			throw new Error(`Stable asset changed: ${file.path}`);
	}
	const report = {
		stableVersion: baseline.version,
		stableFilesPreserved: baseline.files.length - 1,
		changedStableFiles: ["/app/index.html"],
		beta: release,
	};
	await writeFile(`${output}-report.json`, JSON.stringify(report, null, 2));
	if (website) {
		const config = JSON.parse(
			await readFile(path.join(repository, "firebase.deploy.json"), "utf8"),
		);
		const hosting = config.hosting.find((h) => h.target === "public");
		// The generated config can deploy public Hosting only; never Functions, rules or admin.
		hosting.public = output;
		delete hosting.target;
		hosting.site = "better-keep-notes";
		hosting.rewrites.find(
			(r) => r.source === "/oauth/storage/callback",
		).destination = "/storage-auth.html";
		hosting.headers.push(
			{
				source: "/app/{beta-release.json,beta-launcher.js}",
				headers: [{ key: "Cache-Control", value: "no-store" }],
			},
			{
				source: "/app/releases/**",
				headers: [
					{
						key: "Cache-Control",
						value: "public, max-age=31536000, immutable",
					},
				],
			},
		);
		await writeFile(
			`${output}-firebase.json`,
			JSON.stringify({ hosting }, null, 2),
		);
	}
	return report;
}

// Build both storage variants together. Promotion reuses these exact published bytes.
export async function buildBetaRelease(
	version,
	directory = "build/beta-client",
	{ runBuild = run, compileWorker = compileBetaWorker } = {},
) {
	const base = releaseBase(version);
	directory = path.resolve(directory);
	await runBuild("node", [
		"scripts/validate_web_compatibility.mjs",
		"--dart-define-from-file=.env",
	]);
	for (const stable of [false, true]) {
		const output = stable ? path.join(directory, "stable") : directory;
		await runBuild("flutter", [
			"build",
			"web",
			"--release",
			"--base-href=/app/",
			`--output=${output}`,
			"--dart-define-from-file=.env",
			`--dart-define=WEB_BETA=${!stable}`,
			"--pwa-strategy=none",
		]);
		await compileWorker(output);
		await prepareOfflineAssets(output);
		await finalizeBetaBuild(output, version, { stable });
	}
	await writeFile(
		path.join(directory, "beta-build.json"),
		JSON.stringify({
			version,
			base,
			storage: "isolated-v1",
			stableBase: `${base}stable/`,
			workerRuntime: "shared-v1",
		}),
	);
}

async function main() {
	const [command, ...args] = process.argv.slice(2);
	if (command === "build" && args.length === 1) {
		await buildBetaRelease(args[0]);
	} else if (command === "stage" && (args.length === 3 || args.length === 4)) {
		console.log(
			await stageBeta({
				snapshot: args[0],
				beta: args[1],
				output: args[2],
				website: args[3],
			}),
		);
	} else {
		throw new Error(
			"Usage: node tool/beta_web.mjs build RELEASE_ID | stage SNAPSHOT BETA_BUILD NEW_OUTPUT [WEBSITE_BUILD]",
		);
	}
}
if (path.resolve(process.argv[1] || "") === fileURLToPath(import.meta.url)) {
	main().catch((error) => {
		console.error(error.message);
		process.exitCode = 1;
	});
}
