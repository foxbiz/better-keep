import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {
	NOTIFICATION_ICON_RESOURCE,
	resourceHasFilePayload,
} from "../../tool/verify_android_release_resources.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

test("Android shrinker policy preserves the notification icon", () => {
	const keepRule = fs.readFileSync(
		path.join(root, "android/app/src/main/res/raw/keep.xml"),
		"utf8",
	);
	assert.match(keepRule, /tools:keep="@drawable\/ic_stat_better_keep"/);
});

test("release verifier requires an actual shrunk file payload", () => {
	const removed = `resource 0x7f080080 ${NOTIFICATION_ICON_RESOURCE}\nresource 0x7f080081 drawable/next`;
	const retained = `resource 0x7f080080 ${NOTIFICATION_ICON_RESOURCE}\n  () (file) res/drawable/ic_stat_better_keep.xml type=protoXML\nresource 0x7f080081 drawable/next`;
	assert.equal(resourceHasFilePayload(removed, NOTIFICATION_ICON_RESOURCE), false);
	assert.equal(resourceHasFilePayload(retained, NOTIFICATION_ICON_RESOURCE), true);
});
