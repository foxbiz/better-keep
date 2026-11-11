import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import puppeteer from "puppeteer-core";
import { chromeBinary } from "../../tool/chrome_binary.mjs";

test("checkout waits for one SDK load and can retry a failed request", async () => {
	const browser = await puppeteer.launch({ executablePath: chromeBinary() });
	try {
		const page = await browser.newPage();
		await page.setRequestInterception(true);
		const requests = [];
		page.on("request", async (request) => {
			if (request.url() === "https://checkout.razorpay.com/v1/checkout.js")
				requests.push(request);
			else await request.abort();
		});
		await page.addScriptTag({
			content: await readFile("web/js/razorpay_checkout.js", "utf8"),
		});
		assert.equal(requests.length, 0);
		const load = () =>
			page.evaluate(async () =>
				Promise.all([
					window.loadRazorpayCheckout(),
					window.loadRazorpayCheckout(),
				]),
			);
		const nextRequest = () =>
			page.waitForRequest("https://checkout.razorpay.com/v1/checkout.js");
		await page.evaluate(() => {
			window.Razorpay = {};
		});
		const first = nextRequest();
		const failed = load();
		await (await first).abort();
		assert.deepEqual(await failed, [false, false]);
		const second = nextRequest();
		const retried = load();
		await (await second).respond({
			contentType: "application/javascript",
			body: `window.Razorpay = class {
        constructor(options) { this.options = options; }
        on() {}
        open() { this.options.handler({razorpay_subscription_id:this.options.subscription_id}); }
      };`,
		});
		assert.deepEqual(await retried, [true, true]);
		const result = await page.evaluate(() =>
			window.openRazorpaySubscription({
				subscriptionId: "fixture-subscription",
			}),
		);
		assert.equal(result.razorpay_subscription_id, "fixture-subscription");
		assert.equal(result.success, true);
		assert.equal(requests.length, 2);
	} finally {
		await browser.close();
	}
});
