import assert from "node:assert/strict";
import test from "node:test";
import { chromeBinary } from "../../tool/chrome_binary.mjs";
test("CI Chrome and explicit overrides resolve consistently", () => {
	assert.equal(
		chromeBinary({ CHROME_BINARY: "/ci/chrome" }, "linux"),
		"/ci/chrome",
	);
	assert.equal(
		chromeBinary({
			CHROME_BIN: "/custom",
			CHROME_BINARY: "/ci",
			CHROME_EXECUTABLE: "/flutter",
		}),
		"/custom",
	);
	assert.equal(
		chromeBinary({ CHROME_BINARY: "", CHROME_EXECUTABLE: "/flutter" }),
		"/flutter",
	);
	assert.equal(chromeBinary({}, "linux"), "/usr/bin/google-chrome");
	assert.match(chromeBinary({}, "darwin"), /Applications/);
	assert.equal(
		chromeBinary({ PROGRAMFILES: "D:\\Programs" }, "win32"),
		"D:\\Programs\\Google\\Chrome\\Application\\chrome.exe",
	);
});
