import { createHmac, timingSafeEqual } from "node:crypto";
import { Timestamp } from "firebase-admin/firestore";
import { evaluateSubscription } from "./subscriptionEntitlement";

export interface RazorpaySubscriptionEntity {
	cancel_at_cycle_end?: boolean | number | null;
	current_end?: number | null;
	ended_at?: number | null;
	id: string;
	plan_id?: string | null;
	status?: string | null;
}

export function verifyRazorpayWebhookSignature(
	rawBody: Buffer,
	signature: string | undefined,
	secret: string,
): boolean {
	if (!signature || !/^[a-f0-9]{64}$/i.test(signature)) return false;
	const expected = createHmac("sha256", secret).update(rawBody).digest();
	const received = Buffer.from(signature, "hex");
	return (
		received.length === expected.length && timingSafeEqual(received, expected)
	);
}

export function verifyRazorpayWebhookSignatureWithSecrets(
	rawBody: Buffer,
	signature: string | undefined,
	secrets: readonly string[],
): boolean {
	let valid = false;
	for (const secret of secrets) {
		const normalized = secret.trim();
		if (!normalized) continue;
		// Evaluate every configured secret so validation does not reveal which
		// rotation slot matched through a short-circuit timing difference.
		const matches = verifyRazorpayWebhookSignature(
			rawBody,
			signature,
			normalized,
		);
		valid = matches || valid;
	}
	return valid;
}

export function isProcessedRazorpayRefund(refund: {
	status?: string | null;
}): boolean {
	return refund.status?.trim().toLowerCase() === "processed";
}

export function isVerifiedRazorpayPayment(
	payment: {
		amount?: number;
		captured?: boolean;
		created_at?: number;
		currency?: string;
		id?: string;
		status?: string;
	},
	expectedPaymentId: string,
): boolean {
	const status = payment.status?.trim().toLowerCase();
	return (
		payment.id === expectedPaymentId &&
		(status === "captured" || status === "refunded") &&
		payment.captured === true &&
		typeof payment.amount === "number" &&
		Number.isSafeInteger(payment.amount) &&
		payment.amount >= 0 &&
		typeof payment.currency === "string" &&
		/^[A-Z]{3}$/i.test(payment.currency) &&
		typeof payment.created_at === "number" &&
		Number.isSafeInteger(payment.created_at) &&
		payment.created_at >= 0
	);
}

export function verifyRazorpayPaymentSignature(
	paymentId: string,
	subscriptionId: string,
	signature: string,
	secret: string,
): boolean {
	return verifyRazorpayWebhookSignature(
		Buffer.from(`${paymentId}|${subscriptionId}`, "utf8"),
		signature,
		secret,
	);
}

function state(value: string | null | undefined): string {
	return (value ?? "unknown").trim().toUpperCase();
}

export function normalizeRazorpaySubscription({
	billingPeriod,
	entity,
	userId,
	now = Date.now(),
}: {
	billingPeriod?: string | null;
	entity: RazorpaySubscriptionEntity;
	userId: string;
	now?: number;
}): Record<string, unknown> {
	const expiresAt = entity.current_end
		? Timestamp.fromMillis(entity.current_end * 1000)
		: null;
	const cancelAtCycleEnd =
		entity.cancel_at_cycle_end === true || entity.cancel_at_cycle_end === 1;
	const subscriptionState = cancelAtCycleEnd
		? "CANCELED"
		: state(entity.status);
	const base: Record<string, unknown> = {
		plan: "pro",
		source: "razorpay",
		environment: "production",
		userId,
		providerSubscriptionId: entity.id,
		planId: entity.plan_id ?? null,
		billingPeriod: billingPeriod ?? null,
		subscriptionState,
		willAutoRenew: subscriptionState === "ACTIVE" && !cancelAtCycleEnd,
		cancelAtCycleEnd,
		expiresAt,
		endedAt: entity.ended_at
			? Timestamp.fromMillis(entity.ended_at * 1000)
			: null,
	};
	const evaluated = evaluateSubscription(base, now);
	return { ...base, entitlementState: evaluated.entitlementState };
}
