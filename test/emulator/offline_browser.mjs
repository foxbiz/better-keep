// Run with npm test -- offline-browser. Only disposable emulator accounts are used.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import puppeteer from "puppeteer-core";
import { chromeBinary } from "../../tool/chrome_binary.mjs";
import {
	compileBetaWorker,
	finalizeBetaBuild,
	stageBetaRuntime,
} from "../../tool/beta_web.mjs";
import { prepareOfflineAssets } from "../../tool/prepare_offline_assets.mjs";
import { previewServer } from "../../tool/serve_beta_preview.mjs";

const projectId = "demo-better-keep-pairing";
assert.equal(process.env.FIREBASE_AUTH_EMULATOR_HOST, "127.0.0.1:19099");
assert.equal(process.env.FIRESTORE_EMULATOR_HOST, "127.0.0.1:18080");
assert.equal(process.env.GCLOUD_PROJECT, projectId);
const require = createRequire(
	new URL("../../functions/package.json", import.meta.url),
);
const admin = require("firebase-admin/app");
const app = admin.initializeApp({ projectId });
const auth = require("firebase-admin/auth").getAuth(app);
const db = require("firebase-admin/firestore").getFirestore(app);

async function listen(server) {
	await new Promise((resolve, reject) =>
		server.once("error", reject).listen(0, "127.0.0.1", resolve),
	);
	return server.address().port;
}

// Chrome's per-page offline emulation alone doesn't disconnect a service worker.
async function networkProxy(appPort) {
	let offline = false;
	const sockets = new Set();
	function track(socket) {
		sockets.add(socket);
		socket.on("error", () => socket.destroy());
		socket.on("close", () => sockets.delete(socket));
	}
	const proxy = http.createServer((request, response) => {
		const url = new URL(request.url);
		if (
			offline ||
			url.hostname !== "127.0.0.1" ||
			![String(appPort), "18080", "19099"].includes(url.port)
		) {
			response.destroy();
			return;
		}
		const upstream = http.request(
			url,
			{ method: request.method, headers: request.headers },
			(res) => {
				response.writeHead(res.statusCode, res.headers);
				res.pipe(response);
			},
		);
		response.on("close", () => upstream.destroy());
		upstream.on("error", () => response.destroy());
		request.pipe(upstream);
	});
	proxy.on("connection", track);
	proxy.on("connect", (request, client, head) => {
		const [host, port] = request.url.split(":");
		if (
			offline ||
			port !== "443" ||
			!["www.gstatic.com", "fonts.gstatic.com"].includes(host)
		)
			return client.destroy();
		const remote = net.connect(443, host, () => {
			client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
			remote.write(head);
			client.pipe(remote).pipe(client);
		});
		track(remote);
		client.on("close", () => remote.destroy());
		remote.on("close", () => client.destroy());
	});
	return {
		port: await listen(proxy),
		setOffline(value) {
			offline = value;
			if (offline) for (const socket of sockets) socket.destroy();
		},
		close() {
			this.setOffline(true);
			proxy.close();
		},
	};
}

async function exercise(profile, proxy, origin, beta, stableUser) {
	let browser, page;
	async function launch(offline) {
		proxy.setOffline(offline);
		const firefox = process.env.FIREFOX_BIN;
		browser = await puppeteer.launch({
			browser: firefox ? "firefox" : "chrome",
			executablePath: firefox || chromeBinary(),
			userDataDir: profile,
			...(firefox
				? {
						extraPrefsFirefox: {
							"network.proxy.type": 1,
							"network.proxy.http": "127.0.0.1",
							"network.proxy.http_port": proxy.port,
							"network.proxy.ssl": "127.0.0.1",
							"network.proxy.ssl_port": proxy.port,
							"network.proxy.no_proxies_on": "",
							"network.proxy.allow_hijacking_localhost": true,
						},
					}
				: {
						args: [
							`--proxy-server=http://127.0.0.1:${proxy.port}`,
							"--proxy-bypass-list=<-loopback>",
							"--enable-unsafe-swiftshader",
						],
					}),
		});
		page = await browser.newPage();
		page.on("pageerror", (error) =>
			console.error("Browser error:", error.message),
		);
		await page.setOfflineMode(offline);
	}
	async function wait(stage) {
		console.log(`Waiting for ${beta ? "beta" : "stable"} ${stage}`);
		await page.waitForFunction(
			(expected) => {
				const value = document.documentElement.dataset.offlineTest;
				return value === expected || value?.startsWith("failed:");
			},
			{ timeout: 100000 },
			stage,
		).catch(async (error) => {
			const state = await page.evaluate(() => ({
				phase: document.documentElement.dataset.offlineTest,
				controller: navigator.serviceWorker.controller?.scriptURL,
				path: location.pathname,
				scripts: Array.from(document.scripts, (script) => new URL(script.src || location.href).pathname),
				launcher: document.body.innerText.slice(0, 200),
			}));
			throw new Error(`Timed out waiting for ${stage}: ${JSON.stringify(state)}`, {cause: error});
		});
		assert.equal(
			await page.evaluate(() => document.documentElement.dataset.offlineTest),
			stage,
		);
	}
	async function step(value) {
		await page.evaluate(
			(key, next) => localStorage.setItem(key, next),
			beta ? "qa.step.beta" : "qa.step.stable",
			value,
		);
	}
	try {
		await launch(false);
		await page.evaluateOnNewDocument((beta) => {
			if (beta) localStorage.setItem("betterkeep.web.channel.v1", "beta");
			else
				sessionStorage.setItem(
					"betterkeep.web.beta-dismissed.v1",
					"qa-offline",
				);
		}, beta);
		await page.goto(origin + "/");
		await wait("seeded");
		const { qaUser: uid, qaDevice: device } = await page.evaluate(() => ({
			...document.documentElement.dataset,
		}));
		const user = await auth.getUser(uid);
		assert.match(user.email, /^offline-\d+@example\.test$/);
		const expires = Date.now() + 3600000;
		await auth.updateUser(uid, { emailVerified: true });
		await auth.setCustomUserClaims(uid, {
			plan: "pro",
			planExpiresAt: expires,
		});
		await db.doc(`users/${uid}`).set({ email: user.email });
		await db
			.doc(`users/${uid}/subscription/status`)
			.set({ plan: "pro", expiresAt: new Date(expires), source: "emulator" });
		await step("verify-email");
		await page.reload();
		await wait("verified");
		await page.waitForFunction(
			async (beta) => {
				const runtime = beta ? "/app/releases/qa-offline/" : "/app/";
				const cache = await caches.open("better-keep-offline-app-v1");
				const paths = (await cache.keys()).map(
					(req) => new URL(req.url).pathname,
				);
				return (
					navigator.serviceWorker.controller?.scriptURL ===
						new URL(runtime + "offline_worker.js", location.origin).href &&
					paths.includes("/app/index.html") &&
					paths.includes("/app/beta-launcher.js") &&
					paths.includes("/app/beta-release.json") &&
					["sqflite_sw.js", "sqlite3.wasm"].every((name) =>
						paths.includes((beta ? "/app/beta-runtime/v1/" : "/app/") + name),
					) &&
					["main.dart.js", "version.json"].every((name) =>
						paths.includes(runtime + name),
					) &&
					["canvaskit/", "assets/"].every((dir) =>
						paths.some((p) => p.startsWith(runtime + dir)),
					)
				);
			},
			{ timeout: 60000 },
			beta,
		);
		await step("edit");
		proxy.setOffline(true);
		await page.setOfflineMode(true);
		await page.reload();
		await wait("home");
		proxy.setOffline(false);
		await page.setOfflineMode(false);
		await wait("uploaded");

		await step("reopen");
		await browser.close();
		await launch(true);
		await page.goto(origin);
		await wait("home");
		await page.waitForFunction(() =>
			document
				.querySelector("flt-semantics-host")
				?.textContent.includes("Edited while offline"),
		);
		const text = await page.$eval("flt-semantics-host", (el) => el.textContent);
		assert.doesNotMatch(
			text,
			/no internet|sync paused|connect to the internet|no connection available/i,
		);
		proxy.setOffline(false);
		await page.setOfflineMode(false);
		await wait("online");
		// Reject only trust-record writes. All normal Firestore reads still succeed.
		await page.evaluate(() => {
			const put = IDBObjectStore.prototype.put;
			IDBObjectStore.prototype.put = function (...args) {
				if (this.transaction.db.name === "better-keep.device-trust.v1")
					throw new DOMException("fixture", "QuotaExceededError");
				return put.apply(this, args);
			};
		});
		await db
			.doc(`users/${uid}/devices/${device}`)
			.update({ status: "revoked" });
		await wait("revocation-received");
		await step("revoked");
		await browser.close();
		await launch(true);
		await page.goto(origin);
		await wait("locked");
		console.log(
			`${beta ? "Beta" : "Stable"}: offline Home, edit, encrypted upload, cold reopen, and revoked cold start passed`,
		);
		if (beta) {
			assert.notEqual(uid, stableUser);
			await page.evaluate(() =>
				localStorage.removeItem("betterkeep.web.channel.v1"),
			);
			await page.reload();
			await wait("locked");
			assert.equal(
				await page.evaluate(() => document.documentElement.dataset.qaUser),
				stableUser,
				"Offline channel change must open the stable runtime and its own account",
			);
			console.log("Same-profile offline beta to stable switch passed");
		}
		return uid;
	} finally {
		await browser?.close();
	}
}

const root = await mkdtemp(
	path.join(os.tmpdir(), "better-keep-offline-shell-"),
);
try {
	const appDir = path.join(root, "app");
	const version = "qa-offline";
	const base = `/app/releases/${version}/`;
	for (const beta of [false, true]) {
		const output = beta ? path.join(root, base.slice(1)) : appDir;
		execFileSync(
			"flutter",
			[
				"build",
				"web",
				"--no-pub",
				"--release",
				"--no-wasm-dry-run",
				"--base-href=/app/",
				`--output=${output}`,
				`--dart-define=WEB_BETA=${beta}`,
				"--target=test/emulator/offline_browser.dart",
			],
			{ stdio: "inherit" },
		);
		await prepareOfflineAssets(output);
		if (beta) {
			await compileBetaWorker(output);
			await finalizeBetaBuild(output, version);
			await stageBetaRuntime(output, root);
		}
	}
	const entry = path.join(appDir, "index.html");
	await writeFile(
		entry,
		(await readFile(entry, "utf8")).replace(
			'<script src="flutter_bootstrap.js" async></script>',
			'<script src="/app/beta-launcher.js" defer></script>',
		),
	);
	await copyFile(
		"web/js/beta_launcher.js",
		path.join(appDir, "beta-launcher.js"),
	);
	await writeFile(
		path.join(appDir, "beta-release.json"),
		JSON.stringify({
			version,
			base,
			stableBase: base + "stable/",
			storage: "isolated-v1",
			sequence: 1,
			status: "beta",
			stable: null,
		}),
	);
	const profile = await mkdtemp(
		path.join(os.tmpdir(), "better-keep-offline-profile-"),
	);
	const site = previewServer(root, { emulators: true });
	const port = await listen(site);
	const proxy = await networkProxy(port);
	const origin = `http://127.0.0.1:${port}/app`;
	try {
		const stableUser = await exercise(profile, proxy, origin, false);
		await exercise(profile, proxy, origin, true, stableUser);
	} finally {
		proxy.close();
		site.closeAllConnections();
		site.close();
		await rm(profile, { recursive: true, force: true });
	}
} finally {
	await db.terminate();
	await admin.deleteApp(app);
	await rm(root, { recursive: true, force: true });
}
