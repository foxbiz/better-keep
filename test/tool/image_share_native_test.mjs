import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));

test("native image inbox, bounded copies, and provider timeout", {
  skip: process.platform !== "darwin" ? "Requires the macOS Swift SDK" : false,
}, () => {
  const temporary = mkdtempSync(path.join(tmpdir(), "image-share-native-"));
  try {
    const binary = path.join(temporary, "tests");
    const compile = spawnSync("xcrun", [
      "swiftc", "-swift-version", "5", "-module-cache-path", path.join(temporary, "cache"),
      "ios/Shared/ImageShareInbox.swift", "test/native/image_share_test.swift", "-o", binary,
    ], { cwd: root, encoding: "utf8", timeout: 120000 });
    assert.equal(compile.status, 0, compile.stdout + compile.stderr);
    const result = spawnSync(binary, [], { encoding: "utf8", timeout: 10000 });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    console.log(result.stdout.trim());
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
