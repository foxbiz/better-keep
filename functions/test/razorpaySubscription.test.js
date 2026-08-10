const assert = require("node:assert/strict");
const { createHmac } = require("node:crypto");
const test = require("node:test");
const {
	isProcessedRazorpayRefund,
	isVerifiedRazorpayPayment,
	normalizeRazorpaySubscription,
	verifyRazorpayWebhookSignature,
	verifyRazorpayWebhookSignatureWithSecrets,
} = require("../lib/razorpaySubscription");

test("verifies Razorpay signatures against the exact raw request body", () => {
	const secret = "webhook-secret";
	const raw = Buffer.from('{"event":"payment.refunded","amount":1999}');
	const signature = createHmac("sha256", secret).update(raw).digest("hex");
	assert.equal(verifyRazorpayWebhookSignature(raw, signature, secret), true);
	assert.equal(
		verifyRazorpayWebhookSignature(Buffer.from(`${raw} `), signature, secret),
		false,
	);
});

test("accepts current and previous webhook secrets during rotation", () => {
	const raw = Buffer.from('{"event":"refund.processed"}');
	const current = "current-webhook-secret";
	const previous = "previous-webhook-secret";
	for (const signingSecret of [current, previous]) {
		const signature = createHmac("sha256", signingSecret)
			.update(raw)
			.digest("hex");
		assert.equal(
			verifyRazorpayWebhookSignatureWithSecrets(raw, signature, [
				current,
				previous,
			]),
			true,
		);
	}
	assert.equal(
		verifyRazorpayWebhookSignatureWithSecrets(raw, "0".repeat(64), [
			current,
			previous,
		]),
		false,
	);
});

test("only final processed Razorpay refunds qualify for revenue", () => {
	assert.equal(isProcessedRazorpayRefund({ status: "processed" }), true);
	assert.equal(isProcessedRazorpayRefund({ status: "PROCESSED" }), true);
	for (const status of [undefined, null, "pending", "failed"]) {
		assert.equal(isProcessedRazorpayRefund({ status }), false, String(status));
	}
});

test("captured and fully refunded payments remain verified gross charges", () => {
	const payment = {
		id: "pay_live",
		captured: true,
		amount: 1999,
		currency: "USD",
		created_at: 1_786_233_600,
	};
	assert.equal(
		isVerifiedRazorpayPayment(
			{ ...payment, status: "captured" },
			"pay_live",
		),
		true,
	);
	assert.equal(
		isVerifiedRazorpayPayment(
			{ ...payment, status: "refunded" },
			"pay_live",
		),
		true,
	);
	for (const status of ["created", "authorized", "failed"]) {
		assert.equal(
			isVerifiedRazorpayPayment({ ...payment, status }, "pay_live"),
			false,
		);
	}
});

test("cancellation at cycle end keeps access but disables renewal", () => {
	const normalized = normalizeRazorpaySubscription({
		entity: {
			id: "sub_2",
			status: "active",
			cancel_at_cycle_end: 1,
			current_end: 1788825600,
		},
		userId: "uid",
		now: Date.parse("2026-08-08T00:00:00.000Z"),
	});
	assert.equal(normalized.subscriptionState, "CANCELED");
	assert.equal(normalized.entitlementState, "cancelled_access");
	assert.equal(normalized.willAutoRenew, false);
});

test("uses provider current_end instead of receipt time for entitlement", () => {
	const normalized = normalizeRazorpaySubscription({
		entity: { id: "sub_1", status: "active", current_end: 1788825600 },
		userId: "uid",
		now: Date.parse("2026-08-08T00:00:00.000Z"),
	});
	assert.equal(normalized.subscriptionState, "ACTIVE");
	assert.equal(normalized.willAutoRenew, true);
	assert.equal(normalized.expiresAt.toMillis(), 1788825600 * 1000);
});
