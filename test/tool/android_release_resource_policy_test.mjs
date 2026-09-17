import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {
	GOOGLE_WEB_CLIENT_RESOURCE,
	NOTIFICATION_ICON_RESOURCE,
	googleWebClientId,
	resourceHasFilePayload,
	resourceHasStringValue,
} from "../../tool/verify_android_release_resources.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

test("Android shrinker policy preserves the notification icon without overriding library rules", () => {
	const keepRule = fs.readFileSync(
		path.join(root, "android/app/src/main/res/raw/better_keep_keep.xml"),
		"utf8",
	);
	assert.match(keepRule, /tools:keep="@drawable\/ic_stat_better_keep"/);
	assert.equal(fs.existsSync(path.join(root, "android/app/src/main/res/raw/keep.xml")), false);
});

test("release verifier requires an actual shrunk file payload", () => {
	const removed = `resource 0x7f080080 ${NOTIFICATION_ICON_RESOURCE}\nresource 0x7f080081 drawable/next`;
	const retained = `resource 0x7f080080 ${NOTIFICATION_ICON_RESOURCE}\n  () (file) res/drawable/ic_stat_better_keep.xml type=protoXML\nresource 0x7f080081 drawable/next`;
	assert.equal(resourceHasFilePayload(removed, NOTIFICATION_ICON_RESOURCE), false);
	assert.equal(resourceHasFilePayload(retained, NOTIFICATION_ICON_RESOURCE), true);
});

test("release verifier requires the configured web client ID in the shrunk resource", () => {
	const expected = "configured-web-client.apps.googleusercontent.com";
	const resource = `resource 0x7f0f003d ${GOOGLE_WEB_CLIENT_RESOURCE}`;
	const next = `resource 0x7f0f003e string/next\n  () "${expected}"`;
	for (const [name, dump] of Object.entries({
		missing: next,
		removed: `${resource}\n${next}`,
		empty: `${resource}\n  () ""\n${next}`,
		incorrect: `${resource}\n  () "other-client.apps.googleusercontent.com"\n${next}`,
		localizedOnly: `${resource}\n  (en) "${expected}"\n${next}`,
	})) {
		assert.equal(resourceHasStringValue(dump, GOOGLE_WEB_CLIENT_RESOURCE, expected), false, name);
	}
	const valid = `${resource}\n  () "${expected}"\n${next}`;
	assert.equal(resourceHasStringValue(valid, GOOGLE_WEB_CLIENT_RESOURCE, expected), true);
	const proto = `${resource}\n  () "${expected}" src=io.foxbiz.better_keep:/values/values.xml:478\n${next}`;
	assert.equal(resourceHasStringValue(proto, GOOGLE_WEB_CLIENT_RESOURCE, expected), true);
	assert.equal(resourceHasStringValue(valid, GOOGLE_WEB_CLIENT_RESOURCE, ""), false);
});

test("Google client selection uses the web OAuth client for the Android application", () => {
	const client = (packageName, oauthClients) => ({
		client_info: {android_client_info: {package_name: packageName}},
		oauth_client: oauthClients,
	});
	const android = {client_type: 1, client_id: "android-client"};
	const web = {client_type: 3, client_id: "web-client"};
	const target = client("io.foxbiz.better_keep", [android, web]);
	assert.equal(googleWebClientId({client: [client("other.app", [web]), target]}), "web-client");
	assert.equal(googleWebClientId({client: [client("other.app", [web])]}), null);
	assert.equal(googleWebClientId({client: [client("io.foxbiz.better_keep", [android])]}), null);
	assert.equal(googleWebClientId({client: [client("io.foxbiz.better_keep", [{...web, client_id: ""}])]}), null);
});
