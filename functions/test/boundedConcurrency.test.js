const assert = require("node:assert/strict");
const test = require("node:test");
const { forEachBounded } = require("../lib/boundedConcurrency");

test("bounded concurrency never exceeds its configured worker count", async () => {
	let active = 0;
	let peak = 0;
	const completed = [];
	await forEachBounded([0, 1, 2, 3, 4, 5, 6], 3, async (value) => {
		active += 1;
		peak = Math.max(peak, active);
		await new Promise((resolve) => setTimeout(resolve, value % 2));
		completed.push(value);
		active -= 1;
	});
	assert.equal(peak, 3);
	assert.deepEqual(completed.sort((a, b) => a - b), [0, 1, 2, 3, 4, 5, 6]);
});

test("bounded concurrency rejects invalid limits", async () => {
	await assert.rejects(forEachBounded([1], 0, async () => {}), /positive integer/);
});
