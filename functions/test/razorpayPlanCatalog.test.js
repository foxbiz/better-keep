const assert = require("node:assert/strict");
const test = require("node:test");
const { getOrCreateRazorpayPlan } = require("../lib/exports/createRazorpaySubscription");

const plan = {
	id: "plan_lite", period: "monthly", interval: 1,
	item: { name: "better_keep_lite_monthly_usd_v1", amount: 149, currency: "USD" },
};
const lookup = request => getOrCreateRazorpayPlan("test-key", "test-secret", "monthly", "USD", "lite", request);

test("reuses a matching Lite plan beyond the first page without creating another", async () => {
	const paths = [];
	const id = await lookup(async (_key, _secret, method, path) => {
		assert.equal(method, "GET");
		paths.push(path);
		return { items: paths.length === 1 ? Array.from({ length: 100 }, (_, i) => ({ ...plan, item: { ...plan.item, name: `other-${i}` } })) : [plan] };
	});
	assert.equal(id, plan.id);
	assert.deepEqual(paths, ["/plans?count=100&skip=0", "/plans?count=100&skip=100"]);
});

test("a same-name plan with different billing terms fails before checkout", async () => {
	for (const candidate of [
		{ ...plan, period: "yearly" }, { ...plan, interval: 2 },
		{ ...plan, item: { ...plan.item, amount: 299 } },
		{ ...plan, item: { ...plan.item, currency: "INR" } },
	]) {
		await assert.rejects(lookup(async (_key, _secret, method) => {
			assert.equal(method, "GET");
			return { items: [candidate] };
		}), { code: "failed-precondition" });
	}
});

test("creates the correct Lite plan only after a complete empty catalog response", async () => {
	const id = await lookup(async (_key, _secret, method, path, body) => {
		if (method === "GET") return { items: [] };
		assert.equal(path, "/plans");
		assert.equal(body.period, "monthly");
		assert.equal(body.interval, 1);
		assert.equal(body.item.name, plan.item.name);
		assert.equal(body.item.amount, 149);
		assert.equal(body.item.currency, "USD");
		return { id: "new_lite" };
	});
	assert.equal(id, "new_lite");
	await assert.rejects(lookup(async () => ({})), { code: "unavailable" });
});


test("client display amounts match the server catalog for both tiers and currencies", () => {
	const { readFileSync } = require("node:fs");
	const { join } = require("node:path");
	const { razorpayPlanConfig } = require("../lib/config");
	const client = readFileSync(join(__dirname, "../../lib/services/monetization/subscription_service.dart"), "utf8");
	for (const [tier, variable] of [["lite", "razorpayLitePricing"], ["pro", "razorpayPricing"]]) {
		const block = client.split(`${variable} = {`)[1]?.split("};")[0];
		assert.ok(block, `Missing ${variable}`);
		for (const currency of ["USD", "INR"]) {
			const amounts = block.split(`RazorpayCurrency.${currency.toLowerCase()}: {`)[1]?.split("}")[0];
			assert.ok(amounts);
			for (const period of ["monthly", "yearly"]) {
				const amount = Number(new RegExp(`'${period}':\\s*(\\d+)`).exec(amounts)?.[1]);
				assert.equal(amount, razorpayPlanConfig(tier, currency, period).amount, `${tier}/${currency}/${period}`);
			}
		}
	}
});
