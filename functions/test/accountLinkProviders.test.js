const assert = require("node:assert/strict");
const test = require("node:test");
const {
	ACCOUNT_LINK_PROVIDERS,
	accountLinkProviderDisplayName,
	isAccountLinkProvider,
} = require("../lib/accountLinkProviders");

test("Apple is an allowed account-link provider", () => {
	assert.equal(ACCOUNT_LINK_PROVIDERS.includes("apple.com"), true);
	assert.equal(isAccountLinkProvider("apple.com"), true);
	assert.equal(accountLinkProviderDisplayName("apple.com"), "Apple");
});

test("unknown account-link providers remain rejected", () => {
	assert.equal(isAccountLinkProvider("unknown.example"), false);
	assert.equal(isAccountLinkProvider(null), false);
});
