import assert from "node:assert/strict";
import test from "node:test";
import {
	adminScriptSource,
	compareAdminDeployment,
	parseAdminDeploymentArguments,
} from "../../scripts/verify_admin_deployment.mjs";

const currentHtml = (asset = "Current123") => `
  <main data-monthly-gross></main>
  <script type="module" src="/_astro/AdminDashboard.${asset}.js"></script>
`;

test("extracts and compares the hashed dashboard asset", () => {
	assert.equal(
		adminScriptSource(currentHtml()),
		"/_astro/AdminDashboard.Current123.js",
	);
	assert.deepEqual(compareAdminDeployment(currentHtml(), currentHtml()), {
		localScript: "/_astro/AdminDashboard.Current123.js",
		remoteScript: "/_astro/AdminDashboard.Current123.js",
	});
});

test("rejects stale assets and legacy revenue markup", () => {
	assert.throws(
		() => compareAdminDeployment(currentHtml(), currentHtml("Stale456")),
		/asset mismatch/,
	);
	assert.throws(
		() =>
			compareAdminDeployment(
				currentHtml(),
				currentHtml().replace("data-monthly-gross", "data-monthly-revenue"),
			),
		/missing the current revenue breakdown/,
	);
});

test("deployment verification arguments have safe production defaults", () => {
	assert.deepEqual(parseAdminDeploymentArguments([]), {
		attempts: 10,
		delayMillis: 2000,
		local: "build/admin/index.html",
		url: "https://admin.betterkeep.app/",
	});
	assert.throws(
		() => parseAdminDeploymentArguments(["--attempts", "0"]),
		/positive integer/,
	);
});
