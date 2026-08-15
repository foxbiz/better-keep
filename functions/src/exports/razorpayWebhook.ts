import { createHash } from "node:crypto";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { error as logError, info as logInfo } from "firebase-functions/logger";
import { onRequest } from "firebase-functions/v2/https";
import {
	razorpayBillingActivityType,
	writeBillingActivity,
} from "../billingActivity";
import {
	db,
	razorpayKeyId,
	razorpayKeySecret,
	razorpayWebhookSecret,
	razorpayWebhookSecretPrevious,
} from "../config";
import {
	isProcessedRazorpayRefund,
	normalizeRazorpaySubscription,
	type RazorpaySubscriptionEntity,
	verifyRazorpayWebhookSignatureWithSecrets,
} from "../razorpaySubscription";
import { minorUnitsToMicros } from "../revenueLedger";
import { enqueueRevenueEventInTransaction } from "../revenueOutbox";
import { recordSubscriptionIssue } from "../subscriptionIssues";
import { reconcileUserEntitlement } from "../subscriptionReconciler";
import { razorpayRequest } from "../utils";

const RAZORPAY_EVENT_COLLECTION = "razorpayWebhookEvents";
const EVENT_LEASE_MILLIS = 5 * 60 * 1000;

interface RazorpayPaymentEntity {
	amount: number;
	created_at?: number;
	currency: string;
	id: string;
}

interface RazorpayRefundEntity {
	amount: number;
	created_at?: number;
	currency: string;
	id: string;
	payment_id: string;
	status?: string | null;
}

interface RazorpayWebhookEvent {
	event?: string;
	payload?: {
		payment?: { entity?: RazorpayPaymentEntity };
		refund?: { entity?: RazorpayRefundEntity };
		subscription?: { entity?: RazorpaySubscriptionEntity };
	};
}

async function claimEvent(
	eventId: string,
): Promise<"busy" | "claimed" | "succeeded"> {
	const ref = db.collection(RAZORPAY_EVENT_COLLECTION).doc(eventId);
	const now = Timestamp.now();
	return db.runTransaction(async (transaction) => {
		const snapshot = await transaction.get(ref);
		const data = snapshot.data() ?? {};
		if (data.status === "succeeded") return "succeeded";
		if (
			data.status === "processing" &&
			data.leaseUntil instanceof Timestamp &&
			data.leaseUntil.toMillis() > now.toMillis()
		) {
			return "busy";
		}
		transaction.set(
			ref,
			{
				status: "processing",
				attempts: Math.max(0, Number(data.attempts) || 0) + 1,
				leaseUntil: Timestamp.fromMillis(now.toMillis() + EVENT_LEASE_MILLIS),
				createdAt: data.createdAt ?? now,
				updatedAt: now,
			},
			{ merge: true },
		);
		return "claimed";
	});
}

async function finishEvent(
	eventId: string,
	status: "failed" | "succeeded",
	error?: unknown,
): Promise<void> {
	await db
		.collection(RAZORPAY_EVENT_COLLECTION)
		.doc(eventId)
		.set(
			{
				status,
				leaseUntil: null,
				...(status === "succeeded"
					? { processedAt: FieldValue.serverTimestamp() }
					: {
							lastErrorCode:
								typeof (error as { code?: unknown })?.code === "string"
									? (error as { code: string }).code.slice(0, 120)
									: error instanceof Error
										? error.name.slice(0, 120)
										: "unknown",
							lastFailedAt: FieldValue.serverTimestamp(),
						}),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);
}

async function subscriptionOwner(subscriptionId: string): Promise<{
	plan: string | null;
	userId: string;
} | null> {
	const snapshot = await db
		.collection("payments")
		.where("razorpaySubscriptionId", "==", subscriptionId)
		.where("type", "==", "subscription")
		.limit(1)
		.get();
	if (snapshot.empty) return null;
	const data = snapshot.docs[0].data();
	return typeof data.userId === "string"
		? {
				userId: data.userId,
				plan: typeof data.plan === "string" ? data.plan : null,
			}
		: null;
}

async function processSubscriptionEvent(
	eventName: string,
	subscription: RazorpaySubscriptionEntity,
	payment?: RazorpayPaymentEntity,
	activityEventKey = `${eventName}:${subscription.id}:${payment?.id ?? "state"}`,
): Promise<void> {
	const owner = await subscriptionOwner(subscription.id);
	if (!owner) {
		await recordSubscriptionIssue({
			type: "razorpay_unmatched_subscription",
			source: "razorpay",
			providerKey: subscription.id,
			details: { eventName },
		});
		return;
	}
	const normalized = normalizeRazorpaySubscription({
		billingPeriod: owner.plan,
		entity: subscription,
		userId: owner.userId,
	});
	const providerRef = db
		.collection("subscriptions")
		.doc(`razorpay_${subscription.id}`);
	await db.runTransaction(async (transaction) => {
		const existing = await transaction.get(providerRef);
		let revenueEventId: string | null = null;
		if (payment) {
			revenueEventId = await enqueueRevenueEventInTransaction(transaction, {
				provider: "razorpay",
				providerTransactionId: payment.id,
				userId: owner.userId,
				amountMicros: minorUnitsToMicros(payment.amount),
				currency: payment.currency,
				kind: "charge",
				environment: "production",
				occurredAt: payment.created_at
					? new Date(payment.created_at * 1000)
					: new Date(),
				metadata: { subscriptionId: subscription.id, plan: owner.plan },
			});
		}
		transaction.set(
			providerRef,
			{
				...normalized,
				lastVerifiedAt: FieldValue.serverTimestamp(),
				...(!existing.exists
					? { createdAt: FieldValue.serverTimestamp() }
					: {}),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);
		if (payment) {
			transaction.set(
				db.collection("payments").doc(payment.id),
				{
					userId: owner.userId,
					type: "renewal",
					razorpaySubscriptionId: subscription.id,
					razorpayPaymentId: payment.id,
					amount: payment.amount,
					currency: payment.currency,
					status: "verified",
					createdAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);
		}
		writeBillingActivity(transaction, {
			provider: "razorpay",
			eventKey: activityEventKey,
			eventType: razorpayBillingActivityType(eventName, Boolean(payment)),
			occurredAt: payment?.created_at
				? new Date(payment.created_at * 1000)
				: new Date(),
			userId: owner.userId,
			billingPeriod: owner.plan,
			environment: "production",
			subscriptionState:
				typeof normalized.subscriptionState === "string"
					? normalized.subscriptionState
					: null,
			entitlementState:
				typeof normalized.entitlementState === "string"
					? normalized.entitlementState
					: null,
			amountMicros: payment ? minorUnitsToMicros(payment.amount) : null,
			currency: payment?.currency,
			revenueKind: payment ? "charge" : null,
			revenueEventId,
		});
	});
	await reconcileUserEntitlement(owner.userId);
}

async function processRefund(
	refund: RazorpayRefundEntity,
	activityEventKey = `refund:${refund.id}`,
): Promise<void> {
	const paymentSnapshot = await db
		.collection("payments")
		.where("razorpayPaymentId", "==", refund.payment_id)
		.limit(1)
		.get();
	const userId = paymentSnapshot.empty
		? null
		: typeof paymentSnapshot.docs[0].data().userId === "string"
			? (paymentSnapshot.docs[0].data().userId as string)
			: null;
	await db.runTransaction(async (transaction) => {
		const revenueEventId = await enqueueRevenueEventInTransaction(transaction, {
			provider: "razorpay",
			providerTransactionId: refund.id,
			userId,
			amountMicros: minorUnitsToMicros(refund.amount),
			currency: refund.currency,
			kind: "refund",
			environment: "production",
			occurredAt: refund.created_at
				? new Date(refund.created_at * 1000)
				: new Date(),
			metadata: { paymentId: refund.payment_id, refundId: refund.id },
		});
		writeBillingActivity(transaction, {
			provider: "razorpay",
			eventKey: activityEventKey,
			eventType: "refund",
			occurredAt: refund.created_at
				? new Date(refund.created_at * 1000)
				: new Date(),
			userId,
			environment: "production",
			amountMicros: minorUnitsToMicros(refund.amount),
			currency: refund.currency,
			revenueKind: "refund",
			revenueEventId,
		});
		for (const payment of paymentSnapshot.docs) {
			const originalAmount = Number(payment.data().amount);
			transaction.set(
				payment.ref,
				{
					status:
						Number.isFinite(originalAmount) && refund.amount >= originalAmount
							? "refunded"
							: "partially_refunded",
					lastRefundId: refund.id,
					updatedAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);
		}
	});
}

export async function processRazorpayWebhook(
	event: RazorpayWebhookEvent,
	loadRefunds?: (paymentId: string) => Promise<RazorpayRefundEntity[]>,
	activityEventKey?: string,
): Promise<void> {
	const eventName = event.event ?? "unknown";
	const subscription = event.payload?.subscription?.entity;
	const payment = event.payload?.payment?.entity;
	const refund = event.payload?.refund?.entity;

	if (eventName === "refund.processed") {
		if (!refund || !isProcessedRazorpayRefund(refund)) {
			throw new RazorpayRefundNotFinalError();
		}
		await processRefund(refund, activityEventKey);
		return;
	}
	if (eventName === "payment.refunded") {
		if (refund && isProcessedRazorpayRefund(refund)) {
			await processRefund(refund, activityEventKey);
			return;
		}
		if (!payment || !loadRefunds) throw new RazorpayRefundNotFinalError();
		const processedRefunds = (await loadRefunds(payment.id)).filter(
			isProcessedRazorpayRefund,
		);
		if (processedRefunds.length === 0) {
			throw new RazorpayRefundNotFinalError();
		}
		for (const item of processedRefunds) {
			await processRefund(
				item,
				activityEventKey ? `${activityEventKey}:${item.id}` : undefined,
			);
		}
		return;
	}
	if (subscription) {
		await processSubscriptionEvent(
			eventName,
			subscription,
			payment,
			activityEventKey,
		);
	}
}

class RazorpayRefundNotFinalError extends Error {
	readonly code = "razorpay/refund-not-final";

	constructor() {
		super("Razorpay refund is not final");
		this.name = "RazorpayRefundNotFinalError";
	}
}

export default onRequest(
	{
		secrets: [
			razorpayKeyId,
			razorpayKeySecret,
			razorpayWebhookSecret,
			razorpayWebhookSecretPrevious,
		],
	},
	async (req, res) => {
		if (req.method !== "POST") {
			res.status(405).send("Method Not Allowed");
			return;
		}
		const rawBody = req.rawBody;
		const signature = req.headers["x-razorpay-signature"];
		if (
			!verifyRazorpayWebhookSignatureWithSecrets(
				rawBody,
				typeof signature === "string" ? signature : undefined,
				[razorpayWebhookSecret.value(), razorpayWebhookSecretPrevious.value()],
			)
		) {
			res.status(400).send("Invalid signature");
			return;
		}

		const suppliedEventId = req.headers["x-razorpay-event-id"];
		const eventKey =
			typeof suppliedEventId === "string" && suppliedEventId.trim()
				? suppliedEventId.trim()
				: rawBody;
		const eventId = createHash("sha256").update(eventKey).digest("hex");
		const claim = await claimEvent(eventId);
		if (claim === "succeeded") {
			res.status(200).send("OK");
			return;
		}
		if (claim === "busy") {
			res.status(503).send("Processing");
			return;
		}

		try {
			const event = req.body as RazorpayWebhookEvent;
			logInfo("Processing Razorpay webhook", {
				event: "razorpay_webhook",
				eventId,
				type: event.event ?? "unknown",
			});
			await processRazorpayWebhook(
				event,
				async (paymentId) => {
					const response = (await razorpayRequest(
						razorpayKeyId.value().trim(),
						razorpayKeySecret.value().trim(),
						"GET",
						`/payments/${encodeURIComponent(paymentId)}/refunds`,
					)) as { items?: RazorpayRefundEntity[] };
					return (response.items ?? []).filter(
						(item) =>
							isProcessedRazorpayRefund(item) &&
							typeof item.id === "string" &&
							typeof item.amount === "number" &&
							typeof item.currency === "string",
					);
				},
				eventId,
			);
			await finishEvent(eventId, "succeeded");
			res.status(200).send("OK");
		} catch (error) {
			await finishEvent(eventId, "failed", error);
			logError("Razorpay webhook failed", {
				event: "razorpay_webhook_failed",
				eventId,
				errorCode:
					typeof (error as { code?: unknown }).code === "string"
						? (error as { code: string }).code.slice(0, 120)
						: error instanceof Error
							? error.name.slice(0, 120)
							: "unknown",
			});
			res.status(500).send("Internal Server Error");
		}
	},
);
