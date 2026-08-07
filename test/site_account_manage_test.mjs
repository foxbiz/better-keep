import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";

const routePath = "site/src/pages/account/manage.astro";

test("legacy subscription management is private and provider-aware", async () => {
	const route = await readFile(routePath, "utf8");
	assert.match(route, /noindex=\{true\}/);
	assert.match(route, /analytics=\{false\}/);
	assert.match(route, /stripQueryParameters=\{true\}/);
	assert.match(route, /apps\.apple\.com\/account\/subscriptions/);
	assert.match(route, /play\.google\.com\/store\/account\/subscriptions/);
	assert.match(route, /mailto:contact@betterkeep\.app/);
	assert.doesNotMatch(route, /uid|email=/i);
});

test("management destinations contain no account query parameters", async () => {
	const route = await readFile(routePath, "utf8");
	const destinations = [...route.matchAll(/href="(https:[^"]+)"/g)].map(
		(match) => new URL(match[1]),
	);
	assert.equal(destinations.length, 2);
	for (const destination of destinations) {
		assert.equal(destination.search, "");
	}
});
