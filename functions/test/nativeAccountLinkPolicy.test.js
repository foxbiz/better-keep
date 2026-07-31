const assert = require("node:assert/strict");
const test = require("node:test");
const {
	newNativeProviderLink,
} = require("../lib/nativeAccountLinkPolicy");

function event(overrides = {}) {
	return {
		credential: { providerId: "google.com" },
		additionalUserInfo: {
			providerId: "google.com",
			isNewUser: false,
		},
		data: {
			uid: "user-1",
			providerData: [{ providerId: "password" }],
		},
		...overrides,
	};
}

test("detects only a new Google or Apple provider link", () => {
	assert.equal(newNativeProviderLink(event()), "google.com");
	assert.equal(
		newNativeProviderLink(
			event({
				credential: { providerId: "apple.com" },
				additionalUserInfo: {
					providerId: "apple.com",
					isNewUser: false,
				},
			}),
		),
		"apple.com",
	);
	assert.equal(
		newNativeProviderLink(
			event({
				data: {
					uid: "user-1",
					providerData: [{ providerId: "google.com" }],
				},
			}),
		),
		null,
	);
	assert.equal(
		newNativeProviderLink(
			event({
				additionalUserInfo: {
					providerId: "google.com",
					isNewUser: true,
				},
			}),
		),
		null,
	);
	assert.equal(
		newNativeProviderLink(
			event({
				credential: { providerId: "password" },
				additionalUserInfo: {
					providerId: "password",
					isNewUser: false,
				},
			}),
		),
		null,
	);
});
