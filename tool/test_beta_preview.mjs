#!/usr/bin/env node
import { chromeBinary } from "./chrome_binary.mjs";
// A fresh browser profile; production account/backend requests remain blocked.
import assert from "node:assert/strict";
import puppeteer from "puppeteer-core";
const origin = process.argv[2] || "http://127.0.0.1:5099";
const fallback = process.argv.includes("--indexeddb-fallback");
if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(origin))
	throw new Error("Local preview origin required");
const browser = await puppeteer.launch({
	executablePath:
		chromeBinary(),
	headless: true,
	args: ["--no-sandbox"],
});
try {
	const page = await browser.newPage();
	if (fallback)
		await page.evaluateOnNewDocument(() => {
			const original = navigator.storage;
			Object.defineProperty(navigator, "storage", {
				value: new Proxy(original, {
					has: (target, key) =>
						key !== "getDirectory" && Reflect.has(target, key),
					get: (target, key) => {
						if (key === "getDirectory") return undefined;
						const value = Reflect.get(target, key, target);
						return typeof value === "function" ? value.bind(target) : value;
					},
				}),
			});
		});
	let firebaseModule;
	await page.setViewport({ width: 1100, height: 800 });
	await page.setRequestInterception(true);
	page.on("request", (r) => {
		const url = r.url();
		if (
			/^https:\/\/www\.gstatic\.com\/firebasejs\/[^/]+\/firebase-app\.js$/.test(
				url,
			)
		)
			firebaseModule = url;
		const allowed =
			url.startsWith(`${origin}/`) ||
			url.startsWith("data:") ||
			url.startsWith("blob:") ||
			url.startsWith("https://www.gstatic.com/firebasejs/") ||
			url.startsWith("https://fonts.gstatic.com/") ||
			url === "https://accounts.google.com/gsi/client";
		if (allowed) void r.continue();
		else void r.abort();
	});
	await page.evaluateOnNewDocument(() =>
		window.addEventListener(
			"flutter-first-frame",
			() => (window.betaFirstFrame = true),
		),
	);
	await page.goto(`${origin}/app/?channel=beta`);
	await page.waitForSelector("#beta-prompt");
	await page.screenshot({ path: "build/beta-prompt.png" });
	await page.evaluate(async (fallback) => {
		localStorage.setItem("flutter.user_uid", '"stable-sentinel"');
		localStorage.setItem("flutter.e2ee_device_id", '"stable-device"');
		if (fallback) {
			await new Promise((resolve, reject) => {
				const request = indexedDB.open("better_keep_fs", 1);
				request.onupgradeneeded = () =>
					request.result.createObjectStore("sentinels");
				request.onerror = () => reject(request.error);
				request.onsuccess = () => {
					const db = request.result;
					const tx = db.transaction("sentinels", "readwrite");
					tx.objectStore("sentinels").put("stable attachment", "original");
					tx.oncomplete = () => {
						db.close();
						resolve();
					};
				};
			});
		} else {
			const root = await navigator.storage.getDirectory();
			const handle = await root.getFileHandle("stable-sentinel", {
				create: true,
			});
			const writable = await handle.createWritable();
			await writable.write("stable attachment");
			await writable.close();
		}
	}, fallback);
	await page.click("aria/Try beta");
	await page.waitForFunction(() => window.betaFirstFrame === true, {
		timeout: 60000,
	});
	await page.screenshot({ path: "build/beta-first-frame.png" });
	await page.waitForFunction(
		async () =>
			(await indexedDB.databases()).some(
				(db) => db.name === "better_keep_beta_sqlite",
			),
		{ timeout: 30000 },
	);
	await page.evaluate(() =>
		document.querySelector("flt-semantics-placeholder")?.click(),
	);
	await page.waitForFunction(
		() =>
			document
				.querySelector("flt-semantics-host")
				?.textContent.includes("Continue"),
		{ timeout: 15000 },
	);
	const result = await page.evaluate(async (fallback) => {
		const root = fallback ? null : await navigator.storage.getDirectory();
		const stableFile = fallback
			? await new Promise((resolve, reject) => {
					const request = indexedDB.open("better_keep_fs");
					request.onerror = () => reject(request.error);
					request.onsuccess = () => {
						const db = request.result;
						const read = db
							.transaction("sentinels")
							.objectStore("sentinels")
							.get("original");
						read.onsuccess = () => {
							db.close();
							resolve(read.result);
						};
					};
				})
			: await (
					await (await root.getFileHandle("stable-sentinel")).getFile()
				).text();
		return {
			firstFrame: window.betaFirstFrame,
			stableOwner: localStorage.getItem("flutter.user_uid"),
			stableKey: localStorage.getItem("flutter.e2ee_device_id"),
			stableFile,
			betaPreferences: Object.keys(localStorage).filter((k) =>
				k.startsWith("flutter.beta."),
			),
			databaseNames: (await indexedDB.databases()).map((d) => d.name),
			directories: root ? await Array.fromAsync(root.keys()) : [],
		};
	}, fallback);
	assert.equal(result.stableOwner, '"stable-sentinel"');
	assert.equal(result.stableKey, '"stable-device"');
	assert.equal(result.stableFile, "stable attachment");
	assert.ok(result.betaPreferences.length > 0);
	assert.ok(
		fallback
			? result.databaseNames.includes("beta_better_keep_fs")
			: result.directories.includes("better_keep_beta"),
	);
	assert.ok(firebaseModule);
	const firebaseApps = await page.evaluate(
		async (url) => (await import(url)).getApps().map((app) => app.name),
		firebaseModule,
	);
	assert.deepEqual(firebaseApps, ["better-keep-beta"]);
	assert.equal(await page.evaluate(() => location.pathname), "/app/");
	await page.screenshot({ path: "build/beta-running.png" });
	console.log(
		`Beta rendered at /app/ with isolated preferences, Firebase session, SQLite and ${fallback ? "IndexedDB files" : "OPFS"}; stable sentinels unchanged.`,
	);
	console.log(
		JSON.stringify(
			{ databaseNames: result.databaseNames, directories: result.directories },
			null,
			2,
		),
	);
} finally {
	await browser.close();
}
