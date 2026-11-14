#!/usr/bin/env node
import { chromeBinary } from "./chrome_binary.mjs";
// Compiled-client test only: a local fixture and fresh browser profiles, no live APIs.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import puppeteer from "puppeteer-core";
import { previewServer } from "./serve_beta_preview.mjs";
const directory = path.resolve(process.argv[2] || "");
if (!directory.startsWith(path.resolve("build") + path.sep))
	throw new Error("A local build fixture is required");
const manifestFile = path.join(directory, "app/beta-release.json");
const original = await readFile(manifestFile, "utf8");
const release = JSON.parse(original);
if (!release.stableBase || !release.sequence)
	throw new Error("Paired beta fixture required");
const server = previewServer(directory);
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
	browser = await puppeteer.launch({
		executablePath:
			chromeBinary(),
		headless: true,
		args: ["--no-sandbox"],
	});
	async function pageFor(context) {
		const page = await context.newPage();
		let firebaseModule;
		await page.setRequestInterception(true);
		page.on("request", (request) => {
			const url = request.url();
			if (
				/^https:\/\/www\.gstatic\.com\/firebasejs\/[^/]+\/firebase-app\.js$/.test(
					url,
				)
			)
				firebaseModule = url;
			const allowed =
				url.startsWith(`${origin}/`) ||
				/^(data|blob):/.test(url) ||
				url.startsWith("https://www.gstatic.com/firebasejs/") ||
				url.startsWith("https://fonts.gstatic.com/") ||
				url === "https://accounts.google.com/gsi/client";
			void (allowed ? request.continue() : request.abort());
		});
		await page.evaluateOnNewDocument(() =>
			window.addEventListener(
				"flutter-first-frame",
				() => (window.rendered = true),
			),
		);
		return { page, firebaseModule: () => firebaseModule };
	}
	async function ready(client, beta) {
		await client.page.waitForFunction(() => window.rendered, {
			timeout: 60000,
		});
		await client.page.waitForFunction(
			async (name) =>
				(await indexedDB.databases()).some((d) => d.name === name),
			{ timeout: 30000 },
			beta ? "better_keep_beta_sqlite" : "sqflite_databases",
		);
		await client.page.evaluate(() =>
			document.querySelector("flt-semantics-placeholder")?.click(),
		);
		try {
			await client.page.waitForFunction(
				() =>
					/Continue|Unable to start/.test(
						document.querySelector("flt-semantics-host")?.textContent || "",
					),
				{ timeout: 30000 },
			);
			assert.ok(
				await client.page.evaluate(() =>
					document
						.querySelector("flt-semantics-host")
						?.textContent.includes("Continue"),
				),
				"Client failed to start",
			);
		} catch (error) {
			await client.page.screenshot({
				path: "build/hosting-promotion-client-failure.png",
			});
			console.error(
				await client.page.evaluate(() =>
					document
						.querySelector("flt-semantics-host")
						?.textContent?.slice(0, 1200),
				),
			);
			throw error;
		}
		assert.deepEqual(
			await client.page.evaluate(
				async (url) => (await import(url)).getApps().map((a) => a.name),
				client.firebaseModule(),
			),
			[beta ? "better-keep-beta" : "[DEFAULT]"],
		);
	}
	const betaContext = await browser.createBrowserContext();
	const client = await pageFor(betaContext);
	await client.page.goto(`${origin}/app/?channel=beta`);
	await client.page.waitForSelector("#beta-prompt button");
	await client.page.click("aria/Try beta");
	await ready(client, true);
	console.log("Beta client ready");
	await client.page.evaluate(async () => {
		localStorage.setItem(
			"flutter.beta.promotion_sentinel",
			JSON.stringify("keep beta preferences"),
		);
		const root = await navigator.storage.getDirectory();
		const beta = await root.getDirectoryHandle("better_keep_beta");
		const file = await beta.getFileHandle("promotion-sentinel", {
			create: true,
		});
		const writable = await file.createWritable();
		await writable.write("keep beta attachment");
		await writable.close();
	});
	await writeFile(
		manifestFile,
		JSON.stringify({
			...release,
			status: "promoted",
			sequence: release.sequence + 1,
			stable: { version: release.version, base: release.stableBase },
		}),
	);
	await client.page.reload();
	await ready(client, true);
	console.log("Beta client ready");
	assert.equal(await client.page.$("#beta-channel-tag"), null);
	assert.equal(await client.page.$("#beta-prompt"), null);
	const retained = await client.page.evaluate(async () => {
		const root = await navigator.storage.getDirectory();
		const beta = await root.getDirectoryHandle("better_keep_beta");
		let attachment;
		try {
			attachment = await (
				await (await beta.getFileHandle("promotion-sentinel")).getFile()
			).text();
		} catch {
			attachment = `missing; remaining entries: ${JSON.stringify(await Array.fromAsync(beta.keys()))}`;
		}
		return {
			preference: localStorage.getItem("flutter.beta.promotion_sentinel"),
			choice: localStorage.getItem("betterkeep.web.channel.v1"),
			attachment,
		};
	});
	assert.deepEqual(retained, {
		preference: JSON.stringify("keep beta preferences"),
		choice: "beta",
		attachment: "keep beta attachment",
	});
	const second = await pageFor(betaContext);
	await second.page.goto(`${origin}/app/`);
	await ready(second, true);
	console.log("Concurrent beta tab ready");
	assert.equal(
		browser
			.targets()
			.filter(
				(target) =>
					target.type() === "shared_worker" &&
					target.url() === `${origin}/app/beta-runtime/v1/sqflite_sw.js`,
			).length,
		1,
	);

	const stableContext = await browser.createBrowserContext();
	const stable = await pageFor(stableContext);
	await stable.page.evaluateOnNewDocument(() =>
		localStorage.setItem(
			"flutter.promotion_sentinel",
			JSON.stringify("keep stable preferences"),
		),
	);
	await stable.page.goto(`${origin}/app/`);
	await ready(stable, false);
	assert.equal(await stable.page.$("#beta-channel-tag"), null);
	assert.equal(await stable.page.$("#beta-prompt"), null);
	assert.equal(
		await stable.page.evaluate(() =>
			localStorage.getItem("flutter.promotion_sentinel"),
		),
		JSON.stringify("keep stable preferences"),
	);
	assert.equal(
		await stable.page.evaluate(() =>
			localStorage.getItem("betterkeep.web.channel.v1"),
		),
		null,
	);
	assert.ok(
		browser
			.targets()
			.some(
				(target) =>
					target.type() === "shared_worker" &&
					target.url() === `${origin}/app/sqflite_sw.js`,
			),
	);
	console.log(
		"Compiled promotion passed: beta data/session identity retained; stable companion uses stable database/session identity; beta tabs share one database worker; no beta UI after promotion.",
	);
} finally {
	await browser?.close();
	await new Promise((resolve) => server.close(resolve));
	await writeFile(manifestFile, original);
}
