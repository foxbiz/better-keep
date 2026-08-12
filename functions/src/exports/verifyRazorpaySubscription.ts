import { FieldValue, Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import { db, emailPassword, razorpayKeyId, razorpayKeySecret } from "../config";
import { wasEmailDelivered } from "../emailDelivery";
import { onNonReviewCall } from "../nonReviewCallable";
import {
	normalizeRazorpaySubscription,
	type RazorpaySubscriptionEntity,
	verifyRazorpayPaymentSignature,
} from "../razorpaySubscription";
import { minorUnitsToMicros } from "../revenueLedger";
import { enqueueRevenueEventInTransaction } from "../revenueOutbox";
import { reconcileUserEntitlement } from "../subscriptionReconciler";
import { requireVerifiedEntitlementPayload } from "../subscriptionEntitlement";
import { razorpayRequest, sendRazorpaySubscriptionEmail } from "../utils";

/**
 * Verify Razorpay subscription payment
 * Called after successful payment on client
 */
export default onNonReviewCall(
	{
		secrets: [razorpayKeyId, razorpayKeySecret, emailPassword],
	},
	async (
		request: CallableRequest<{
			subscriptionId: string;
			paymentId: string;
			signature: string;
		}>,
	) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}
		const userId = request.auth.uid;
		const { subscriptionId, paymentId, signature } = request.data;

		console.log(
			`Verifying Razorpay subscription ${subscriptionId} for user ${userId}`,
		);

		try {
			const keySecret = razorpayKeySecret.value().trim();

			if (
				!verifyRazorpayPaymentSignature(
					paymentId,
					subscriptionId,
					signature,
					keySecret,
				)
			) {
				console.error("Invalid Razorpay signature");
				throw new HttpsError("invalid-argument", "Invalid payment signature");
			}

			// Get payment details from Firebase
			const paymentDoc = await db
				.collection("payments")
				.doc(subscriptionId)
				.get();

			if (!paymentDoc.exists) {
				throw new HttpsError("not-found", "Payment not found");
			}

			const paymentData = paymentDoc.data();
			if (!paymentData) {
				throw new HttpsError("not-found", "Payment data not found");
			}

			if (paymentData.userId !== userId) {
				throw new HttpsError(
					"permission-denied",
					"Payment does not belong to user",
				);
			}

			const keyId = razorpayKeyId.value().trim();
			const providerPayment = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/payments/${encodeURIComponent(paymentId)}`,
			)) as {
				amount?: number;
				created_at?: number;
				currency?: string;
				id?: string;
				status?: string;
			};
			if (
				providerPayment.id !== paymentId ||
				providerPayment.status !== "captured" ||
				typeof providerPayment.amount !== "number" ||
				!Number.isSafeInteger(providerPayment.amount) ||
				typeof providerPayment.currency !== "string"
			) {
				throw new HttpsError(
					"failed-precondition",
					"Razorpay payment is not captured",
				);
			}
			const providerSubscription = (await razorpayRequest(
				keyId,
				keySecret,
				"GET",
				`/subscriptions/${encodeURIComponent(subscriptionId)}`,
			)) as RazorpaySubscriptionEntity;
			if (
				providerSubscription.id !== subscriptionId ||
				!providerSubscription.current_end
			) {
				throw new HttpsError(
					"failed-precondition",
					"Razorpay subscription state is incomplete",
				);
			}
			const normalized = normalizeRazorpaySubscription({
				billingPeriod:
					typeof paymentData.plan === "string" ? paymentData.plan : null,
				entity: providerSubscription,
				userId,
			});
			const expiresAt = normalized.expiresAt;
			if (!(expiresAt instanceof Timestamp)) {
				throw new HttpsError(
					"failed-precondition",
					"Razorpay subscription has no expiry",
				);
			}

			const revenueEvent = {
				provider: "razorpay",
				providerTransactionId: paymentId,
				userId,
				amountMicros: minorUnitsToMicros(providerPayment.amount),
				currency: providerPayment.currency,
				kind: "charge",
				environment: "production",
				occurredAt: providerPayment.created_at
					? new Date(providerPayment.created_at * 1000)
					: new Date(),
				metadata: { subscriptionId, plan: paymentData.plan ?? null },
			} as const;
			const providerRef = db
				.collection("subscriptions")
				.doc(`razorpay_${subscriptionId}`);
			await db.runTransaction(async (transaction) => {
				const existingProvider = await transaction.get(providerRef);
				await enqueueRevenueEventInTransaction(transaction, revenueEvent);
				transaction.set(
					providerRef,
					{
						...normalized,
						lastVerifiedAt: FieldValue.serverTimestamp(),
						...(!existingProvider.exists
							? { createdAt: FieldValue.serverTimestamp() }
							: {}),
						updatedAt: FieldValue.serverTimestamp(),
					},
					{ merge: true },
				);
				transaction.update(paymentDoc.ref, {
					status: "verified",
					razorpayPaymentId: paymentId,
					razorpaySignature: signature,
					verifiedAt: FieldValue.serverTimestamp(),
				});
			});
			await reconcileUserEntitlement(userId);

			console.log(
				`Activated subscription for user ${userId}, expires ${expiresAt.toDate().toISOString()}`,
			);

			// Send welcome email only once (idempotency guard).
			// Email is sent first; flag is written only after a successful send so a
			// transient mailer failure doesn't permanently suppress the welcome email.
			const alreadySentWelcome = paymentData.welcomeEmailSent === true;
			if (!alreadySentWelcome) {
				try {
					const delivery = await sendRazorpaySubscriptionEmail(
						userId,
						"welcome",
						expiresAt.toDate(),
					);
					if (wasEmailDelivered(delivery)) {
						await paymentDoc.ref.update({ welcomeEmailSent: true });
					}
				} catch (emailError) {
					console.error(
						`Subscription activated, but welcome email failed for ${userId}:`,
						emailError,
					);
				}
			}

			return {
				success: true,
				expiryDate: expiresAt.toDate().toISOString(),
				subscription: requireVerifiedEntitlementPayload(normalized),
			};
		} catch (error) {
			console.error("Error verifying Razorpay subscription:", error);
			if (error instanceof HttpsError) throw error;
			throw new HttpsError("internal", "Failed to verify subscription");
		}
	},
);
