const assert = require("node:assert/strict");
const test = require("node:test");
const {
	hasReviewAccess,
	isAllowedReviewSignIn,
	isProtectedReviewIdentity,
	isProtectedReviewUserRecord,
	isReviewAccountEmail,
	requireNonReviewAccess,
	requireReviewAccess,
} = require("../lib/reviewAccess");

const reviewAuth = {
	uid: "review-uid",
	token: {
		email: "review@betterkeep.app",
		appReview: true,
	},
};

test("recognizes only the configured review email", () => {
	assert.equal(isReviewAccountEmail(" review@betterkeep.app "), true);
	assert.equal(isReviewAccountEmail("REVIEW@BETTERKEEP.APP"), true);
	assert.equal(isReviewAccountEmail("other@example.com"), false);
	assert.equal(isReviewAccountEmail(undefined), false);
});

test("accepts only the review email with the boolean appReview claim", () => {
	assert.equal(hasReviewAccess(reviewAuth), true);
	assert.equal(
		hasReviewAccess({
			uid: "review-uid",
			token: { email: "review@betterkeep.app" },
		}),
		false,
	);
	assert.equal(
		hasReviewAccess({
			uid: "review-uid",
			token: { email: "review@betterkeep.app", appReview: "true" },
		}),
		false,
	);
	assert.equal(
		hasReviewAccess({
			uid: "other-uid",
			token: { email: "other@example.com", appReview: true },
		}),
		false,
	);
});

test("review authorization fails closed", () => {
	assert.throws(
		() => requireReviewAccess(undefined),
		(error) => error.code === "unauthenticated",
	);
	assert.throws(
		() =>
			requireReviewAccess({
				uid: "other-uid",
				token: { email: "other@example.com", appReview: true },
			}),
		(error) => error.code === "permission-denied",
	);
	assert.equal(requireReviewAccess(reviewAuth).uid, "review-uid");
});

test("mutation protection matches either review marker", () => {
	const emailOnly = {
		uid: "email-only",
		token: { email: "review@betterkeep.app" },
	};
	const claimOnly = {
		uid: "claim-only",
		token: { email: "other@example.com", appReview: true },
	};
	const ordinary = {
		uid: "ordinary",
		token: { email: "other@example.com" },
	};

	assert.equal(isProtectedReviewIdentity(emailOnly), true);
	assert.equal(isProtectedReviewIdentity(claimOnly), true);
	assert.equal(isProtectedReviewIdentity(reviewAuth), true);
	assert.equal(isProtectedReviewIdentity(ordinary), false);
	assert.throws(
		() => requireNonReviewAccess(emailOnly),
		(error) => error.code === "permission-denied",
	);
	assert.throws(
		() => requireNonReviewAccess(claimOnly),
		(error) => error.code === "permission-denied",
	);
	assert.equal(requireNonReviewAccess(ordinary).uid, "ordinary");
});

test("user-record protection matches either review marker", () => {
	assert.equal(
		isProtectedReviewUserRecord({ email: "review@betterkeep.app" }),
		true,
	);
	assert.equal(
		isProtectedReviewUserRecord({
			email: "other@example.com",
			customClaims: { appReview: true },
		}),
		true,
	);
	assert.equal(
		isProtectedReviewUserRecord({
			email: "other@example.com",
			customClaims: {},
		}),
		false,
	);
});

test("protected review identities may sign in only with password", () => {
	const emailOnly = { email: "review@betterkeep.app" };
	const claimOnly = {
		email: "other@example.com",
		customClaims: { appReview: true },
	};

	for (const reviewUser of [emailOnly, claimOnly]) {
		assert.equal(
			isAllowedReviewSignIn(reviewUser, "providers/cloud.auth/eventTypes/user.beforeSignIn:password"),
			true,
		);
		assert.equal(
			isAllowedReviewSignIn(reviewUser, "providers/cloud.auth/eventTypes/user.beforeSignIn:google.com"),
			false,
		);
		assert.equal(isAllowedReviewSignIn(reviewUser, undefined), false);
	}

	assert.equal(
		isAllowedReviewSignIn(
			{ email: "ordinary@example.com" },
			"providers/cloud.auth/eventTypes/user.beforeSignIn:google.com",
		),
		true,
	);
});
