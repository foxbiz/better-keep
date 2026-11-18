import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));

test("signed image-share policy with an available Python 3 runtime", (t) => {
  const candidates = process.platform === "win32"
    ? [["py", ["-3"]], ["python3", []], ["python", []]]
    : [["python3", []], ["python", []]];
  const runtime = candidates.find(([command, args]) => {
    const result = spawnSync(command, [...args, "-c", "import sys; sys.exit(sys.version_info.major != 3)"], { timeout: 10000 });
    return result.status === 0;
  });
  if (!runtime) {
    assert.ok(!process.env.CI, "CI must provide Python 3 for signing-policy tests");
    t.skip("Python 3 unavailable; install python3, python, or the Windows py launcher to run signing-policy tests");
    return;
  }
  const [command, args] = runtime;
  const result = spawnSync(command, [...args, "test/tool/image_share_signing_test.py"], {
    cwd: root, encoding: "utf8", timeout: 30000,
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

test("archive-only jobs skip signing checks; declared exports must be verified", {
  skip: process.platform === "win32" ? "Xcode Cloud hook requires a POSIX shell" : false,
}, () => {
  const directory = mkdtempSync(path.join(tmpdir(), "image-share-hook-"));
  const run = (extra) => spawnSync("sh", ["ios/ci_scripts/ci_post_xcodebuild.sh"], {
    cwd: root, encoding: "utf8",
    env: {
      ...process.env,
      CI_XCODEBUILD_ACTION: "archive", CI_PRODUCT_PLATFORM: "iOS", CI_XCODEBUILD_EXIT_CODE: "0",
      CI_APP_STORE_SIGNED_APP_PATH: "", CI_AD_HOC_SIGNED_APP_PATH: "", CI_DEVELOPMENT_SIGNED_APP_PATH: "",
      IMAGE_SHARE_REQUIRE_SIGNED_EXPORT: "0", ...extra,
    },
  });
  try {
    let result = run({});
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /archive-only/);
    result = run({ IMAGE_SHARE_REQUIRE_SIGNED_EXPORT: "1" });
    assert.notEqual(result.status, 0, "Distribution workflows must require an export");
    result = run({ CI_APP_STORE_SIGNED_APP_PATH: path.join(directory, "missing") });
    assert.notEqual(result.status, 0, "A declared but missing export must not silently skip verification");
    const exported = path.join(directory, "signed.ipa");
    writeFileSync(exported, "test export");
    writeFileSync(path.join(directory, "python3"), '#!/bin/sh\nprintf "%s\\n" "$@"\n', { mode: 0o755 });
    result = run({ CI_APP_STORE_SIGNED_APP_PATH: exported, PATH: `${directory}:${process.env.PATH}` });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /verify_ios_image_share_signing.py/);
    assert.ok(result.stdout.includes(exported));
    result = run({ CI_XCODEBUILD_EXIT_CODE: "65", IMAGE_SHARE_REQUIRE_SIGNED_EXPORT: "1" });
    assert.equal(result.status, 0, "Do not mask an earlier build failure");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
