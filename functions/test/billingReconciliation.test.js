const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
	applyAfterProviderPreflight,
	classifyRazorpayProviderFailure,
	isAuthoritativelySelectedSource,
	providerReference,
	sanitizedErrorCode,
	storedOnlySubscriptionRow,
	storedProviderCounts,
	verifiedReconciliationUserIds,
} = require("../lib/billingReconciliation");
const { RazorpayApiError } = require("../lib/utils");

test("classifies only record-specific Razorpay 400 and 404 failures as non-blocking", () => {
	for (const status of [400, 404]) {
		assert.deepEqual(
			classifyRazorpayProviderFailure(new RazorpayApiError(status)),
			{ blocking: false, failureClass: "unresolved", status },
		);
	}
});

test("sanitizes operational errors to a bounded code without leaking messages", () => {
	const error = new Error("secret provider response body");
	error.code = "auth/quota-project-missing";
	assert.equal(sanitizedErrorCode(error), "auth/quota-project-missing");
	assert.doesNotMatch(sanitizedErrorCode(error), /secret|provider|response/);
	assert.equal(sanitizedErrorCode(new TypeError("sensitive")), "TypeError");
	assert.equal(sanitizedErrorCode({}), "unknown");
});

test("blocks Razorpay credentials, throttling, network, and provider failures", () => {
	for (const [status, failureClass] of [
		[401, "configuration"],
		[403, "configuration"],
		[429, "retryable"],
		[500, "retryable"],
		[503, "retryable"],
		[null, "retryable"],
	]) {
		assert.deepEqual(
			classifyRazorpayProviderFailure(new RazorpayApiError(status)),
			{ blocking: true, failureClass, status },
		);
	}
});

test("blocking preflight failures prevent every apply callback", async () => {
	let writes = 0;
	await assert.rejects(
		applyAfterProviderPreflight(
			[{ blocking: true, failureClass: "retryable", status: 503 }],
			async () => {
				writes += 1;
			},
		),
		/Provider preflight blocked execution/,
	);
	assert.equal(writes, 0);

	await applyAfterProviderPreflight(
		[{ blocking: false, failureClass: "unresolved", status: 400 }],
		async () => {
			writes += 1;
		},
	);
	assert.equal(writes, 1);
});

test("all provider selection excludes unaudited App Store records", () => {
	assert.equal(isAuthoritativelySelectedSource("all", "play_store"), true);
	assert.equal(isAuthoritativelySelectedSource("all", "razorpay"), true);
	assert.equal(isAuthoritativelySelectedSource("all", "app_store"), false);
	assert.equal(isAuthoritativelySelectedSource("play", "play_store"), true);
	assert.equal(isAuthoritativelySelectedSource("play", "razorpay"), false);
	assert.equal(isAuthoritativelySelectedSource("razorpay", "razorpay"), true);
	assert.equal(
		isAuthoritativelySelectedSource("razorpay", "app_store"),
		false,
	);
});

test("stored provider counts distinguish entitlement from production-paid access", () => {
	const expiry = Timestamp.fromDate(new Date("2099-01-01T00:00:00.000Z"));
	assert.deepEqual(
		storedProviderCounts([
			{
				source: "app_store",
				plan: "pro",
				environment: "unknown",
				status: "ACTIVE",
				expiresAt: expiry,
			},
			{
				source: "play_store",
				plan: "pro",
				environment: "production",
				status: "SUBSCRIPTION_STATE_ACTIVE",
				expiresAt: expiry,
			},
		]),
		{
			app_store: { effectiveEntitled: 1, known: 1, productionPaid: 0 },
			play_store: { effectiveEntitled: 1, known: 1, productionPaid: 1 },
		},
	);
});

test("stored-only reports preserve App Store records and redact provider keys", () => {
	const providerKey = "sensitive-original-transaction-id";
	const row = storedOnlySubscriptionRow({
		providerKey,
		data: {
			source: "app_store",
			userId: "firebase-uid",
			plan: "pro",
			environment: "production",
			status: "EXPIRED",
			expiresAt: Timestamp.fromMillis(1),
		},
	});
	assert.equal(row.intendedAction, "preserve_stored_only");
	assert.equal(row.firebaseUserId, "firebase-uid");
	assert.equal(row.providerRef, providerReference("app_store", providerKey));
	assert.equal(JSON.stringify(row).includes(providerKey), false);
});

test("only verified provider records reconcile each owner once", () => {
	assert.deepEqual(
		verifiedReconciliationUserIds([
			{ kind: "persist", userId: "uid-b" },
			{ kind: "issue", userId: "uid-failed" },
			{ kind: "missing_user", userId: "uid-deleted" },
			{ kind: "persist", userId: "uid-a" },
			{ kind: "persist", userId: "uid-b" },
		]),
		["uid-a", "uid-b"],
	);
});
