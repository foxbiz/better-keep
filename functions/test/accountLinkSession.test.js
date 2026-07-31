const assert = require("node:assert/strict");
const test = require("node:test");
const {
	isValidAccountLinkSession,
} = require("../lib/accountLinkSession");

function session(overrides = {}) {
	return {
		uid: "user-1",
		provider: "github.com",
		status: "issued",
		authorizationExpiresAt: { toMillis: () => 2_000 },
		consumedAt: null,
		...overrides,
	};
}

test("account-link sessions bind the UID and provider", () => {
	const expectation = {
		uid: "user-1",
		provider: "github.com",
		nowMs: 1_000,
	};

	assert.equal(isValidAccountLinkSession(session(), expectation), true);
	assert.equal(
		isValidAccountLinkSession(session({ uid: "user-2" }), expectation),
		false,
	);
	assert.equal(
		isValidAccountLinkSession(
			session({ provider: "facebook.com" }),
			expectation,
		),
		false,
	);
});

test("account-link sessions reject expiry, replay, and malformed data", () => {
	const expectation = {
		provider: "github.com",
		nowMs: 2_000,
	};

	assert.equal(
		isValidAccountLinkSession(
			session({ authorizationExpiresAt: { toMillis: () => 2_000 } }),
			expectation,
		),
		false,
	);
	assert.equal(
		isValidAccountLinkSession(session({ consumedAt: {} }), expectation),
		false,
	);
	assert.equal(
		isValidAccountLinkSession(
			session({ status: "native_authorized" }),
			expectation,
		),
		false,
	);
	assert.equal(
		isValidAccountLinkSession(session({ status: undefined }), expectation),
		false,
	);
	assert.equal(isValidAccountLinkSession(null, expectation), false);
	assert.equal(
		isValidAccountLinkSession(session({ uid: undefined }), expectation),
		false,
	);
});
