const assert = require("node:assert/strict");
const test = require("node:test");
const {
	hasAdminAccess,
	mergeAdminClaim,
	removeAdminClaim,
	requireAdminAccess,
	requireRecentAdminAccess,
} = require("../lib/adminAccess");

process.env.ADMIN_ACCOUNT_UID = "admin-uid";

const authorized = {
	uid: "admin-uid",
	token: {
		email: "admin@betterkeep.app",
		email_verified: true,
		appAdmin: true,
		auth_time: 1_000,
		firebase: {
			sign_in_provider: "password",
			sign_in_second_factor: "totp",
		},
	},
};

test("admin access requires configured UID, verification, claim, password, and TOTP", () => {
	assert.equal(hasAdminAccess(authorized), true);
	for (const candidate of [
		{ ...authorized, uid: "other-user" },
		{ ...authorized, token: { ...authorized.token, email_verified: false } },
		{ ...authorized, token: { ...authorized.token, appAdmin: false } },
		{
			...authorized,
			token: { ...authorized.token, firebase: { ...authorized.token.firebase, sign_in_provider: "google.com" } },
		},
		{
			...authorized,
			token: { ...authorized.token, firebase: { ...authorized.token.firebase, sign_in_second_factor: undefined } },
		},
	]) {
		assert.equal(hasAdminAccess(candidate), false);
	}
});

test("authorization fails closed when the UID is not configured", () => {
	const configured = process.env.ADMIN_ACCOUNT_UID;
	delete process.env.ADMIN_ACCOUNT_UID;
	assert.equal(hasAdminAccess(authorized), false);
	process.env.ADMIN_ACCOUNT_UID = configured;
	assert.equal(requireAdminAccess(authorized).uid, "admin-uid");
	assert.throws(() => requireAdminAccess(undefined), (error) => error.code === "unauthenticated");
});

test("mutations require authentication from the previous 15 minutes", () => {
	assert.equal(requireRecentAdminAccess(authorized, 1_899).uid, "admin-uid");
	assert.throws(
		() => requireRecentAdminAccess(authorized, 1_901),
		(error) => error.code === "failed-precondition",
	);
	assert.throws(
		() => requireRecentAdminAccess({ ...authorized, token: { ...authorized.token, auth_time: undefined } }, 1_000),
		(error) => error.code === "failed-precondition",
	);
});

test("admin claim helpers preserve unrelated claims", () => {
	assert.deepEqual(mergeAdminClaim({ plan: "pro", appReview: false }), {
		plan: "pro",
		appReview: false,
		appAdmin: true,
	});
	assert.deepEqual(removeAdminClaim({ plan: "pro", appAdmin: true }), { plan: "pro" });
});
