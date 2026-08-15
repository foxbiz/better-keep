const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");

const adminApi = readFileSync("src/adminApi.ts", "utf8");
const appStoreWebhook = readFileSync("src/exports/appStoreWebhook.ts", "utf8");
const razorpayWebhook = readFileSync("src/exports/razorpayWebhook.ts", "utf8");
const stats = readFileSync("src/exports/updatePublicStats.ts", "utf8");
const ledger = readFileSync("src/revenueLedger.ts", "utf8");
const outbox = readFileSync("src/revenueOutbox.ts", "utf8");
const utils = readFileSync("src/utils.ts", "utf8");

test("every admin callable enforces App Check and mutations consume limited-use tokens", () => {
	for (const callable of [
		"adminGetOverview",
		"adminListBillingActivity",
		"adminListUsers",
		"adminGetUser",
	]) {
		assert.match(adminApi, new RegExp(`${callable}[\\s\\S]{0,120}enforceAppCheck: true`));
	}
	for (const callable of ["adminSetUserDisabled", "adminRevokeUserSessions"]) {
		assert.match(
			adminApi,
			new RegExp(`${callable}[\\s\\S]{0,180}enforceAppCheck: true, consumeAppCheckToken: true`),
		);
	}
});

test("overview exposes independent request, user, and revenue freshness", () => {
	assert.match(adminApi, /schemaVersion: 2/);
	assert.match(adminApi, /generatedAt:/);
	assert.match(adminApi, /totalUsersUpdatedAt,/);
	assert.match(adminApi, /revenueUpdatedAt:/);
	assert.match(stats, /totalUsersUpdatedAt: FieldValue\.serverTimestamp\(\)/);
	assert.match(ledger, /revenueUpdatedAt: FieldValue\.serverTimestamp\(\)/);
	assert.match(adminApi, /health: \{/);
	assert.match(adminApi, /actionable: \{/);
	assert.match(adminApi, /quarantined: \{/);
});

test("billing activity is paginated, filterable, and omits raw provider identifiers", () => {
	assert.match(adminApi, /adminListBillingActivity/);
	assert.match(adminApi, /where\("provider", "==", provider\)/);
	assert.match(adminApi, /where\("eventType", "==", eventType\)/);
	assert.match(adminApi, /orderBy\("occurredAt", "desc"\)/);
	assert.match(adminApi, /nextCursor:/);
	const activityCallable = adminApi.slice(
		adminApi.indexOf("export const adminListBillingActivity"),
		adminApi.indexOf("export const adminListUsers"),
	);
	assert.doesNotMatch(activityCallable, /providerTransactionId|purchaseToken|orderId/);
});

test("search queries both normalized email and display name after segment selection", () => {
	assert.match(adminApi, /\["emailLower", "displayNameLower"\]/);
	assert.match(adminApi, /segmentQuery\(segment\)[\s\S]{0,100}orderBy\(field\)/);
});

test("existing revenue ledger entries are immutable idempotency records", () => {
	assert.match(ledger, /if \(existing\.exists\) return;/);
	assert.match(ledger, /transaction\.create\(transactionRef, nextData\)/);
});

test("attempted Auth mutations remain pending until their outcomes are reconciled", () => {
	for (const mutation of ["auth.updateUser", "auth.revokeRefreshTokens"]) {
		assert.match(
			adminApi,
			new RegExp(`markMutationStarted\\(\\);[\\s\\S]{0,80}${mutation.replace(".", "\\.")}`),
		);
	}
});

test("App Store state and revenue events share durable transactions", () => {
	for (const source of [appStoreWebhook, utils]) {
		assert.match(
			source,
			/runTransaction[\s\S]{0,3000}enqueueRevenueEventInTransaction/,
		);
	}
});

test("completed App Store notification UUIDs are replay-safe", () => {
	assert.match(appStoreWebhook, /collection\("appStoreWebhookEvents"\)/);
	assert.match(
		appStoreWebhook,
		/existingEvent\.exists[\s\S]{0,120}status\(200\)/,
	);
});

test("Razorpay refunds require final provider status and use webhook secrets", () => {
	assert.match(razorpayWebhook, /isProcessedRazorpayRefund/);
	assert.match(razorpayWebhook, /RazorpayRefundNotFinalError/);
	assert.match(razorpayWebhook, /razorpayWebhookSecret\.value\(\)/);
	assert.match(razorpayWebhook, /razorpayWebhookSecretPrevious\.value\(\)/);
	assert.doesNotMatch(
		razorpayWebhook,
		/verifyRazorpayWebhookSignatureWithSecrets\([\s\S]{0,180}razorpayKeySecret\.value/,
	);
});

test("dead-lettered revenue events emit structured alerts", () => {
	assert.match(outbox, /event: "admin_revenue_dead_letter"/);
	assert.match(outbox, /eventId,/);
	assert.match(outbox, /errorCode:/);
});
