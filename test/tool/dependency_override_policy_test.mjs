import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const packageJson = JSON.parse(readFileSync("package.json", "utf8"));

test("UUID compatibility overrides are scoped to gaxios", () => {
	assert.equal(packageJson.overrides.uuid, undefined);
	assert.deepEqual(packageJson.overrides.gaxios, { uuid: "^11.1.1" });
});
