#!/usr/bin/env node
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { fileURLToPath } from "node:url";
import { randomUUID, createHash } from "node:crypto";
import { readFile, writeFile, mkdir, cp, mkdtemp, rm } from "node:fs/promises";
import { runChildProcess } from "./process_runner.mjs";
import { buildBetaRelease, stageBetaRuntime } from "./beta_web.mjs";
import { connectHosting, snapshotHosting } from "./hosting_live.mjs";
import {
	readJson,
	hostedPath,
	copyHostedFile,
	listHostedFiles,
	hashHostedFiles,
	verifySnapshot,
} from "./hosting_files.mjs";

const reportHash = (report) =>
	createHash("sha256").update(JSON.stringify(report)).digest("hex");
const repository = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
);
export const HOSTING_TARGETS = Object.freeze({
	"hosting-web": {
		website: true,
		app: null,
		description: "Deploy website only; preserve the live app.",
	},
	"hosting-app-beta": {
		website: false,
		app: "beta",
		description: "Deploy an opt-in web app beta; preserve the website.",
	},
	"hosting-app-prod": {
		website: false,
		app: "prod",
		description: "Promote the live beta; preserve the website.",
	},
	"hosting-beta": {
		website: true,
		app: "beta",
		description: "Deploy website and opt-in web app beta.",
	},
	"hosting-prod": {
		website: true,
		app: "prod",
		description: "Deploy website and promote the live beta.",
	},
});
export function parseHostingArguments(target, args) {
	if (!Object.hasOwn(HOSTING_TARGETS, target))
		throw new Error(`Unknown Hosting target: ${target}`);
	if (!args.length) return { target };
	if (args.length === 1 && args[0] === "--prepare-only")
		return { target, prepareOnly: true };
	if (args.length === 2 && args[0] === "--publish")
		return { target, publish: path.resolve(args[1]) };
	throw new Error(
		"Hosting accepts only --prepare-only or --publish PREPARED_DIRECTORY",
	);
}
function validateRelease(release) {
	if (
		!release ||
		!/^[a-z0-9-]{1,80}$/.test(release.version) ||
		release.base !== `/app/releases/${release.version}/` ||
		release.storage !== "isolated-v1" ||
		release.workerRuntime !== "shared-v1" ||
		release.stableBase !== `${release.base}stable/`
	)
		throw new Error(
			"Beta release is missing a valid paired stable build; publish a new beta first",
		);
}
async function optionalRelease(directory) {
	try {
		const release = await readJson(
			path.join(directory, "app/beta-release.json"),
		);
		if (
			!release ||
			typeof release !== "object" ||
			(release.sequence !== undefined &&
				(!Number.isSafeInteger(release.sequence) || release.sequence < 1)) ||
			(release.stable &&
				(!/^[a-z0-9-]{1,80}$/.test(release.stable.version) ||
					release.stable.base !==
						`/app/releases/${release.stable.version}/stable/`))
		)
			throw new Error(
				"Live release manifest is invalid; refusing to advance it",
			);
		return release;
	} catch (error) {
		if (error.code === "ENOENT") return null;
		throw error;
	}
}
function setHeader(config, glob, headers) {
	config.headers ??= [];
	config.headers = config.headers.filter((entry) => entry.glob !== glob);
	config.headers.push({ glob, headers });
}
async function overlayWebsite(directory, website, config) {
	const files = await listHostedFiles(website);
	if (!files.includes("/index.html"))
		throw new Error("Website build is missing index.html");
	if (files.some((f) => f === "/app" || f.startsWith("/app/")))
		throw new Error("Website build must not contain /app files");
	for (const file of files) await copyHostedFile(website, directory, file);
	for (const folder of ["icons", ".well-known", "js"]) {
		for (const file of await listHostedFiles(
			path.join(repository, "web", folder),
		)) {
			if (file === "/firebase_emulator_proxy.js") continue;
			await copyHostedFile(
				path.join(repository, "web"),
				directory,
				`/${folder}${file}`,
			);
		}
	}
	for (const page of [
		"auth",
		"reset-password",
		"desktop-checkout",
		"storage-auth",
	])
		await copyHostedFile(
			path.join(repository, "web"),
			directory,
			`/${page}.html`,
		);
	const callback = await readFile(
		path.join(directory, "storage-auth.html"),
		"utf8",
	);
	const scripts = [
		...callback.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g),
	];
	if (scripts.length !== 1)
		throw new Error("Unrecognized OAuth callback script");
	const hash = createHash("sha256").update(scripts[0][1]).digest("base64");
	config.rewrites = [
		{ glob: "/oauth/storage/callback", path: "/storage-auth.html" },
		...(config.rewrites || []).filter(
			(r) => r.glob !== "/oauth/storage/callback",
		),
	];
	// Preserve the old /app callback policy while replacing only website paths.
	config.headers = (config.headers || []).map((entry) =>
		entry.glob ===
		"/{oauth/storage/callback,app/storage-auth.html,storage-auth.html}"
			? { ...entry, glob: "/app/storage-auth.html" }
			: entry,
	);
	// Only website/callback headers change; /app stays byte-for-byte intact.
	setHeader(config, "/{oauth/storage/callback,storage-auth.html}", {
		"Content-Security-Policy": `default-src 'none'; script-src 'sha256-${hash}'; style-src 'unsafe-inline'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'`,
		"Cache-Control": "no-store",
		"Referrer-Policy": "no-referrer",
	});
}
function assertPreserved(baseline, files, definition) {
	for (const file of baseline.files) {
		const app = file.path.startsWith("/app/");
		if (
			(app ? !definition.app : !definition.website) &&
			files[file.path] !== file.hash
		)
			throw new Error(`Out-of-scope file changed: ${file.path}`);
		if (
			(file.path.startsWith("/app/releases/") ||
				file.path.startsWith("/app/beta-runtime/")) &&
			files[file.path] !== file.hash
		)
			throw new Error(`Published release asset changed: ${file.path}`);
	}
	const previous = new Set(baseline.files.map((f) => f.path));
	for (const name of Object.keys(files)) {
		if (
			!previous.has(name) &&
			(name.startsWith("/app/") ? !definition.app : !definition.website)
		)
			throw new Error(`Out-of-scope file added: ${name}`);
	}
}

export async function stageHostingRelease({
	target,
	snapshot,
	output,
	beta,
	website,
}) {
	const definition = HOSTING_TARGETS[target];
	if (!Object.hasOwn(HOSTING_TARGETS, target))
		throw new Error("Unknown Hosting target");
	output = path.resolve(output);
	for (const input of [snapshot, beta, website]
		.filter(Boolean)
		.map((p) => path.resolve(p))) {
		if (
			output === input ||
			output.startsWith(`${input}${path.sep}`) ||
			input.startsWith(`${output}${path.sep}`)
		)
			throw new Error("Release output must be separate from its inputs");
	}
	const baseline = await verifySnapshot(snapshot);
	if (!baseline.completeSite || !baseline.config)
		throw new Error("A complete live Hosting snapshot is required");
	await mkdir(output); // No overwrite or reuse of an incomplete build.
	const directory = path.join(output, "public");
	await mkdir(directory);
	for (const file of baseline.files)
		await copyHostedFile(snapshot, directory, file.path);
	const config = structuredClone(baseline.config);
	if (definition.website) {
		if (!website) throw new Error("Website build required");
		await overlayWebsite(directory, website, config);
	}
	let release = await optionalRelease(directory);
	if (definition.app === "beta") {
		const candidate = await readJson(path.join(beta, "beta-build.json"));
		validateRelease(candidate);
		if (baseline.files.some((f) => f.path.startsWith(candidate.base)))
			throw new Error("Release ID already published; build a new ID");
		const companion = await readJson(path.join(beta, "stable/beta-build.json"));
		if (
			companion.base !== candidate.stableBase ||
			companion.version !== candidate.version ||
			companion.storage !== "stable-v1"
		)
			throw new Error("Stable companion does not match the beta");
		for (const file of [
			"flutter_bootstrap.js",
			"main.dart.js",
			"sqflite_sw.js",
			"stable/flutter_bootstrap.js",
			"stable/main.dart.js",
			"stable/sqflite_sw.js",
		])
			await readFile(path.join(beta, file));
		await stageBetaRuntime(beta, directory);
		await cp(beta, hostedPath(directory, candidate.base), { recursive: true });
		release = {
			...candidate,
			status: "beta",
			sequence: (release?.sequence || 0) + 1,
			stable: release?.stable || null,
		};
		const indexFile = path.join(directory, "app/index.html");
		const index = await readFile(indexFile, "utf8");
		const entry =
			/<script\s+src=["']flutter_bootstrap\.js["']\s+async><\/script>/g;
		if ([...index.matchAll(entry)].length === 1)
			await writeFile(
				indexFile,
				index.replace(
					entry,
					'<script src="/app/beta-launcher.js" defer></script>',
				),
			);
		else if (
			!index.includes('<script src="/app/beta-launcher.js" defer></script>')
		)
			throw new Error("Unrecognized app bootstrap; refusing to replace it");
		await cp(
			path.join(repository, "web/js/beta_launcher.js"),
			path.join(directory, "app/beta-launcher.js"),
		);
	} else if (definition.app === "prod") {
		validateRelease(release);
		if (release.status !== "beta")
			throw new Error("No unpromoted live beta is available");
		const companion = await readJson(
			hostedPath(directory, `${release.stableBase}beta-build.json`),
		);
		if (
			companion.base !== release.stableBase ||
			companion.version !== release.version ||
			companion.storage !== "stable-v1"
		)
			throw new Error("Live stable companion does not match beta");
		for (const base of [release.base, release.stableBase]) {
			for (const file of [
				"flutter_bootstrap.js",
				"main.dart.js",
				"sqflite_sw.js",
			])
				await readFile(hostedPath(directory, `${base}${file}`));
		}
		release = {
			...release,
			status: "promoted",
			sequence: (release.sequence || 0) + 1,
			stable: { version: release.version, base: release.stableBase },
		};
	}
	if (definition.app) {
		await writeFile(
			path.join(directory, "app/beta-release.json"),
			JSON.stringify(release),
		);
		setHeader(config, "/app/{index.html,beta-release.json,beta-launcher.js}", {
			"Cache-Control": "no-store",
		});
		setHeader(config, "/app/beta-runtime/**", {
			"Cache-Control": "public, max-age=31536000, immutable",
		});
		setHeader(config, "/app/releases/**", {
			"Cache-Control": "public, max-age=31536000, immutable",
		});
	}
	const files = await hashHostedFiles(directory);
	assertPreserved(baseline, files, definition);
	const report = {
		target,
		baseline: baseline.version,
		config,
		files,
		release: definition.app ? release : null,
		changed: Object.keys(files).filter(
			(name) =>
				baseline.files.find((f) => f.path === name)?.hash !== files[name],
		),
	};
	await writeFile(
		path.join(output, "release.json"),
		JSON.stringify({ ...report, integrity: reportHash(report) }, null, 2),
	);
	return report;
}

export async function publishHostingRelease(prepared, target, api) {
	const { integrity, ...report } = await readJson(
		path.join(prepared, "release.json"),
	);
	if (integrity !== reportHash(report))
		throw new Error("Prepared release report was modified; prepare again");
	if (report.target !== target || !Object.hasOwn(HOSTING_TARGETS, target))
		throw new Error("Prepared release target mismatch");
	const directory = path.join(prepared, "public");
	const files = await hashHostedFiles(directory);
	if (JSON.stringify(files) !== JSON.stringify(report.files))
		throw new Error("Prepared release files were modified; prepare again");
	const assertLive = async () => {
		if ((await api.live()).name !== report.baseline)
			throw new Error("Live Hosting changed; prepare again before deployment");
	};
	await assertLive();
	const version = await api.create();
	await api.upload(version, directory, Object.keys(files));
	if (
		JSON.stringify(await hashHostedFiles(directory)) !== JSON.stringify(files)
	)
		throw new Error(
			"Prepared release files changed during upload; prepare again",
		);
	await api.finalize(version, report.config);
	const finalized = await api.version(version);
	if (
		finalized.status !== "FINALIZED" ||
		!isDeepStrictEqual(finalized.config, report.config)
	)
		throw new Error("Finalized Hosting configuration differs; release blocked");
	await assertLive(); // Abort if another release landed while uploading.
	await api.release(
		version,
		`${target}${report.release ? ` ${report.release.version}` : ""}`,
	);
	console.log(`Published ${target}: ${version}`);
	return version;
}
async function validateWebsite(prepared) {
	const result = await runChildProcess({
		command: "node",
		args: ["scripts/validate_visibility.mjs", path.join(prepared, "public")],
		cwd: repository,
		env: process.env,
	});
	if (result !== 0)
		throw new Error("Website validation failed; release blocked");
}
async function main() {
	const [target, ...args] = process.argv.slice(2);
	const options = parseHostingArguments(target, args);
	const definition = HOSTING_TARGETS[target];
	const releases = path.join(repository, "build/hosting-releases");
	await mkdir(releases, { recursive: true });
	const lock = path.join(releases, ".lock");
	try {
		await mkdir(lock);
	} catch {
		throw new Error(
			"Another Hosting operation is running (build/hosting-releases/.lock)",
		);
	}
	try {
		const api = await connectHosting();
		let prepared = options.publish;
		if (!prepared) {
			const work = await mkdtemp(path.join(releases, `${target}-`));
			const snapshot = path.join(work, "snapshot");
			await snapshotHosting(snapshot, { api });
			let beta;
			if (definition.app === "beta") {
				beta = path.join(work, "client");
				await buildBetaRelease(
					`beta-${Date.now()}-${randomUUID().slice(0, 8)}`,
					beta,
				);
			}
			if (definition.website) {
				const result = await runChildProcess({
					command: "npm",
					args: ["--prefix", "site", "run", "build"],
					cwd: repository,
					env: process.env,
				});
				if (result !== 0) throw new Error(`Website build failed (${result})`);
			}
			prepared = path.join(work, "prepared");
			const report = await stageHostingRelease({
				target,
				snapshot,
				output: prepared,
				beta,
				website: definition.website
					? path.join(repository, "site/dist")
					: undefined,
			});
			if (definition.website) {
				await validateWebsite(prepared);
			}
			console.log(
				`Prepared ${target}: ${report.changed.length} changed files. Review ${prepared}/release.json`,
			);
		}
		if (options.prepareOnly)
			console.log(
				`Not deployed. After review: npm run deploy ${target} -- --publish ${prepared}`,
			);
		else {
			if (options.publish && definition.website) {
				await validateWebsite(prepared);
			}
			await publishHostingRelease(prepared, target, api);
		}
	} finally {
		await rm(lock, { recursive: true, force: true });
	}
}
if (path.resolve(process.argv[1] || "") === fileURLToPath(import.meta.url)) {
	main().catch((error) => {
		console.error(error.message);
		process.exitCode = 1;
	});
}
