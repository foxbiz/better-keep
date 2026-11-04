import { chromeBinary } from "../../tool/chrome_binary.mjs";
import assert from "node:assert/strict";
import { test, before, after } from "node:test";
import { mkdtemp, mkdir, writeFile, copyFile, rm } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import puppeteer from "puppeteer-core";
import { previewServer } from "../../tool/serve_beta_preview.mjs";
let root, server, browser, origin;
const release = {
	version: "beta-test",
	base: "/app/releases/beta-test/",
	storage: "isolated-v1",
};
before(async () => {
	root = await mkdtemp(path.join(os.tmpdir(), "beta-launcher-"));
	await mkdir(path.join(root, release.base), { recursive: true });
	await writeFile(
		path.join(root, "app/index.html"),
		'<html><head><base href="/app/"></head><body><script src="/app/beta-launcher.js" defer></script></body></html>',
	);
	await copyFile(
		"web/js/beta_launcher.js",
		path.join(root, "app/beta-launcher.js"),
	);
	await writeFile(
		path.join(root, "app/beta-release.json"),
		JSON.stringify(release),
	);
	await writeFile(
		path.join(root, "app/flutter_bootstrap.js"),
		'window.loadedVersion="stable";',
	);
	await writeFile(
		path.join(root, release.base, "flutter_bootstrap.js"),
		'window.loadedVersion="beta";window.dispatchEvent(new Event("flutter-first-frame"));',
	);
	server = previewServer(root);
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	origin = `http://127.0.0.1:${server.address().port}`;
	browser = await puppeteer.launch({
		executablePath:
			chromeBinary(),
		headless: true,
		args: ["--no-sandbox"],
	});
});
after(async () => {
	await browser?.close();
	if (server) await new Promise((resolve) => server.close(resolve));
	if (root) await rm(root, { recursive: true, force: true });
});
async function fresh() {
	const context = await browser.createBrowserContext();
	return { context, page: await context.newPage() };
}
async function button(page, label) {
	await page.evaluate(
		(label) =>
			[...document.querySelectorAll("#beta-prompt button")]
				.find((b) => b.textContent === label)
				.click(),
		label,
	);
}

test("declining downloads only stable and remembers dismissal", async () => {
	const { context, page } = await fresh();
	const requests = [];
	page.on("request", (r) => requests.push(r.url()));
	await page.goto(`${origin}/app/`);
	await page.waitForSelector("#beta-prompt");
	assert.equal(await page.evaluate(() => window.loadedVersion), undefined);
	assert.ok(!requests.some((url) => url.includes("/releases/")));
	await button(page, "Not now");
	await page.waitForFunction(() => window.loadedVersion === "stable");
	await page.reload();
	await page.waitForFunction(() => window.loadedVersion === "stable");
	assert.ok(!requests.some((url) => url.includes("/releases/")));
	await context.close();
});
test("acceptance persists across tabs and never starts stable", async () => {
	const { context, page } = await fresh();
	const requests = [];
	page.on("request", (r) => requests.push(r.url()));
	await page.goto(`${origin}/app/`);
	await page.waitForSelector("#beta-prompt");
	await button(page, "Try beta");
	await page.waitForFunction(() => window.loadedVersion === "beta");
	assert.equal(
		await page.$eval("#beta-channel-tag", (e) => e.textContent),
		"Beta",
	);
	assert.equal(await page.$("#beta-prompt"), null);
	assert.equal(await page.evaluate(() => location.pathname), "/app/");
	assert.ok(!requests.some((url) => url.endsWith("/app/flutter_bootstrap.js")));
	const other = await context.newPage();
	await other.goto(`${origin}/app/`);
	await other.waitForFunction(() => window.loadedVersion === "beta");
	await context.close();
});
test("mobile prompt fits, Escape declines, and accepting shows progress until ready", async () => {
	const { context, page } = await fresh();
	await page.setViewport({ width: 320, height: 568 });
	await page.goto(`${origin}/app?`);
	await page.waitForSelector("#beta-prompt");
	const bounds = await page.$eval("#beta-prompt", (dialog) => {
		const rect = dialog.getBoundingClientRect();
		return {
			left: rect.left,
			right: rect.right,
			top: rect.top,
			bottom: rect.bottom,
			fits: dialog.scrollWidth === dialog.clientWidth,
			described: dialog.getAttribute("aria-describedby"),
		};
	});
	assert.ok(
		bounds.left >= 0 &&
			bounds.right <= 320 &&
			bounds.top >= 0 &&
			bounds.bottom <= 568 &&
			bounds.fits,
	);
	assert.equal(bounds.described, "beta-prompt-description beta-prompt-note");
	await page.keyboard.press("Escape");
	await page.waitForFunction(() => window.loadedVersion === "stable");
	await page.evaluate(() => sessionStorage.clear());
	let resume;
	await page.setRequestInterception(true);
	page.on("request", (request) => {
		if (
			request.url().includes("/releases/") &&
			request.resourceType() === "fetch"
		) {
			resume = () => request.continue();
		} else void request.continue();
	});
	await page.reload();
	await page.waitForSelector("#beta-prompt");
	await button(page, "Try beta");
	await page.waitForSelector('#beta-prompt [role="status"]');
	assert.equal(await page.$("#beta-prompt button"), null);
	await page.keyboard.press("Escape");
	assert.ok(await page.$("#beta-prompt[open]"));
	assert.equal(
		await page.evaluate(() =>
			localStorage.getItem("betterkeep.web.channel.v1"),
		),
		null,
	);
	assert.ok(resume);
	await resume();
	await page.waitForFunction(() => window.loadedVersion === "beta");
	assert.equal(await page.$("#beta-prompt"), null);
	await context.close();
});
test("missing beta release fails closed for opted-in browsers but stable still starts for others", async () => {
	const { context, page } = await fresh();
	await page.goto(`${origin}/app/`);
	await page.waitForSelector("#beta-prompt");
	await button(page, "Try beta");
	await page.waitForFunction(() => window.loadedVersion === "beta");
	await writeFile(path.join(root, "app/beta-release.json"), "{}");
	try {
		await page.reload();
		await page.waitForSelector("#beta-prompt");
		assert.equal(await page.evaluate(() => window.loadedVersion), undefined);
		assert.ok(
			(await page.$eval("#beta-prompt", (e) => e.innerText)).includes(
				"Unable to start",
			),
		);
		const freshContext = await browser.createBrowserContext();
		const freshPage = await freshContext.newPage();
		await freshPage.goto(`${origin}/app/`);
		await freshPage.waitForFunction(() => window.loadedVersion === "stable");
		await freshContext.close();
	} finally {
		await writeFile(
			path.join(root, "app/beta-release.json"),
			JSON.stringify(release),
		);
		await context.close();
	}
});
test("unavailable beta bootstrap cannot commit an upgrade or fall back silently", async () => {
	const { context, page } = await fresh();
	await page.setRequestInterception(true);
	page.on("request", (r) =>
		r.url().includes("/releases/")
			? r.respond({ status: 404, body: "missing" })
			: r.continue(),
	);
	await page.goto(`${origin}/app/`);
	await page.waitForSelector("#beta-prompt");
	await button(page, "Try beta");
	await page.waitForFunction(() =>
		document
			.querySelector("#beta-prompt")
			?.textContent.includes("Unable to start"),
	);
	assert.equal(await page.evaluate(() => window.loadedVersion), undefined);
	assert.equal(
		await page.evaluate(() =>
			localStorage.getItem("betterkeep.web.channel.v1"),
		),
		null,
	);
	await context.close();
});

test("storage OAuth callback returns only to its same-origin opener", async () => {
	const { context, page } = await fresh();
	await page.goto(`${origin}/app/`);
	await page.waitForSelector("#beta-prompt");
	const result = await page.evaluate(
		() =>
			new Promise((resolve, reject) => {
				const timer = setTimeout(
					() => reject(new Error("Callback did not return")),
					5000,
				);
				const popup = window.open(
					`/oauth/storage/callback?state=${"A".repeat(43)}&code=synthetic-only`,
				);
				window.addEventListener("message", function listener(event) {
					if (event.data?.type !== "betterkeep-storage-oauth") return;
					clearTimeout(timer);
					window.removeEventListener("message", listener);
					resolve({
						sameOrigin: event.origin === location.origin,
						samePopup: event.source === popup,
						type: event.data.type,
					});
				});
			}),
	);
	assert.deepEqual(result, {
		sameOrigin: true,
		samePopup: true,
		type: "betterkeep-storage-oauth",
	});
	await context.close();
});

test("promotion keeps each storage variant, removes beta UI, and refuses older or missing manifests", async () => {
	const { context, page } = await fresh();
	const stableBase = `${release.base}stable/`;
	await mkdir(path.join(root, stableBase), { recursive: true });
	await writeFile(
		path.join(root, stableBase, "flutter_bootstrap.js"),
		'window.loadedVersion="promoted-stable";window.dispatchEvent(new Event("flutter-first-frame"));',
	);
	try {
		await page.goto(`${origin}/app/`);
		await page.waitForSelector("#beta-prompt");
		await button(page, "Try beta");
		await page.waitForFunction(() => window.loadedVersion === "beta");
		const promoted = {
			...release,
			stableBase,
			status: "promoted",
			sequence: 2,
			stable: { version: release.version, base: stableBase },
		};
		await writeFile(
			path.join(root, "app/beta-release.json"),
			JSON.stringify(promoted),
		);
		await page.reload();
		await page.waitForFunction(() => window.loadedVersion === "beta");
		assert.equal(await page.$("#beta-channel-tag"), null);
		assert.equal(await page.$("#beta-prompt"), null);
		assert.equal(await page.title(), "Better Keep");
		assert.equal(
			await page.evaluate(() =>
				localStorage.getItem("betterkeep.web.channel.v1"),
			),
			"beta",
		);
		const stableContext = await browser.createBrowserContext();
		try {
			const stablePage = await stableContext.newPage();
			await stablePage.goto(`${origin}/app/`);
			await stablePage.waitForFunction(
				() => window.loadedVersion === "promoted-stable",
			);
			assert.equal(
				await stablePage.evaluate(() => new URL(document.baseURI).pathname),
				"/app/",
			);
			assert.equal(await stablePage.$("#beta-channel-tag"), null);
			assert.equal(await stablePage.$("#beta-prompt"), null);
			assert.equal(
				await stablePage.evaluate(() =>
					localStorage.getItem("betterkeep.web.channel.v1"),
				),
				null,
			);
			// A new beta offer must decline to the promoted stable, not the old /app bootstrap.
			await writeFile(
				path.join(root, "app/beta-release.json"),
				JSON.stringify({ ...promoted, status: "beta", sequence: 3 }),
			);
			await stablePage.reload();
			await stablePage.waitForSelector("#beta-prompt");
			await button(stablePage, "Not now");
			await stablePage.waitForFunction(
				() => window.loadedVersion === "promoted-stable",
			);
			for (const oldManifest of [promoted, {}]) {
				await writeFile(
					path.join(root, "app/beta-release.json"),
					JSON.stringify(oldManifest),
				);
				await stablePage.reload();
				await stablePage.waitForSelector("#beta-prompt");
				assert.equal(
					await stablePage.evaluate(() => window.loadedVersion),
					undefined,
				);
				assert.match(
					await stablePage.$eval("#beta-prompt", (e) => e.textContent),
					/Unable to start/,
				);
			}
		} finally {
			await stableContext.close();
		}
	} finally {
		await writeFile(
			path.join(root, "app/beta-release.json"),
			JSON.stringify(release),
		);
		await context.close();
	}
});

test("stable promotion still opens when local storage writes are blocked", async () => {
	const { context, page } = await fresh();
	const manifest = {
		...release,
		status: "promoted",
		sequence: 1,
		stable: { version: release.version, base: `${release.base}stable/` },
	};
	await mkdir(path.join(root, manifest.stable.base), { recursive: true });
	await writeFile(
		path.join(root, manifest.stable.base, "flutter_bootstrap.js"),
		'window.loadedVersion="promoted-stable";window.dispatchEvent(new Event("flutter-first-frame"));',
	);
	await writeFile(
		path.join(root, "app/beta-release.json"),
		JSON.stringify(manifest),
	);
	try {
		await page.evaluateOnNewDocument(() => {
			Storage.prototype.setItem = () => {
				throw new DOMException("Synthetic quota error", "QuotaExceededError");
			};
		});
		await page.goto(`${origin}/app/`);
		await page.waitForFunction(
			() => window.loadedVersion === "promoted-stable",
		);
		assert.equal(await page.$("#beta-prompt"), null);
	} finally {
		await writeFile(
			path.join(root, "app/beta-release.json"),
			JSON.stringify(release),
		);
		await context.close();
	}
});
