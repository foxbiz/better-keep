import * as crypto from "node:crypto";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { db, razorpayKeySecret } from "../config";
import { setSubscriptionClaims } from "../utils";

/**
 * Razorpay webhook handler
 * Handles subscription lifecycle events
 */
export default onRequest(
	{
		secrets: [razorpayKeySecret],
	},
	async (req, res) => {
		if (req.method !== "POST") {
			res.status(405).send("Method Not Allowed");
			return;
		}

		const signature = req.headers["x-razorpay-signature"] as string;
		const body = JSON.stringify(req.body);

		try {
			const keySecret = razorpayKeySecret.value().trim();

			// Verify webhook signature
			const expectedSignature = crypto
				.createHmac("sha256", keySecret)
				.update(body)
				.digest("hex");

			if (signature !== expectedSignature) {
				console.error("Invalid Razorpay webhook signature");
				res.status(400).send("Invalid signature");
				return;
			}

			const event = req.body;
			console.log(`Razorpay webhook: ${event.event}`);

			switch (event.event) {
				case "subscription.charged": {
					// Subscription renewal successful
					const subscription = event.payload.subscription.entity;
					const payment = event.payload.payment.entity;

					// Find user by subscription ID
					const paymentsQuery = await db
						.collection("payments")
						.where("razorpaySubscriptionId", "==", subscription.id)
						.limit(1)
						.get();

					if (!paymentsQuery.empty) {
						const paymentDoc = paymentsQuery.docs[0];
						const userId = paymentDoc.data().userId;

						// Calculate new expiry
						const now = new Date();
						const expiryDate = new Date(now);
						const plan = paymentDoc.data().plan;
						if (plan === "yearly") {
							expiryDate.setFullYear(expiryDate.getFullYear() + 1);
						} else {
							expiryDate.setMonth(expiryDate.getMonth() + 1);
						}

						// Update subscription
						await db
							.collection("users")
							.doc(userId)
							.collection("subscription")
							.doc("status")
							.update({
								razorpayPaymentId: payment.id,
								expiryDate: Timestamp.fromDate(expiryDate),
								subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
								updatedAt: FieldValue.serverTimestamp(),
							});

						// Update custom claims for server-side enforcement
						await setSubscriptionClaims(userId, "pro", expiryDate);

						// Record the payment
						await db.collection("payments").add({
							userId,
							type: "renewal",
							razorpaySubscriptionId: subscription.id,
							razorpayPaymentId: payment.id,
							amount: payment.amount,
							currency: payment.currency,
							status: "verified",
							createdAt: FieldValue.serverTimestamp(),
						});

						console.log(`Renewed subscription for user ${userId}`);
					}
					break;
				}

				case "subscription.cancelled": {
					const subscription = event.payload.subscription.entity;

					const paymentsQuery = await db
						.collection("payments")
						.where("razorpaySubscriptionId", "==", subscription.id)
						.limit(1)
						.get();

					if (!paymentsQuery.empty) {
						const userId = paymentsQuery.docs[0].data().userId;

						await db
							.collection("users")
							.doc(userId)
							.collection("subscription")
							.doc("status")
							.update({
								autoRenew: false,
								subscriptionState: "SUBSCRIPTION_STATE_CANCELED",
								updatedAt: FieldValue.serverTimestamp(),
							});

						console.log(`Subscription cancelled for user ${userId}`);
					}
					break;
				}

				case "subscription.halted":
				case "subscription.expired": {
					const subscription = event.payload.subscription.entity;

					const paymentsQuery = await db
						.collection("payments")
						.where("razorpaySubscriptionId", "==", subscription.id)
						.limit(1)
						.get();

					if (!paymentsQuery.empty) {
						const userId = paymentsQuery.docs[0].data().userId;

						// Remove subscription
						await db
							.collection("users")
							.doc(userId)
							.collection("subscription")
							.doc("status")
							.delete();

						// Clear custom claims - user is now on free plan
						await setSubscriptionClaims(userId, "free", null);

						console.log(`Subscription expired/halted for user ${userId}`);
					}
					break;
				}

				case "payment.failed": {
					const payment = event.payload.payment.entity;
					console.log(`Payment failed: ${payment.id}`);
					// You could notify the user here
					break;
				}

				default:
					console.log(`Unhandled Razorpay event: ${event.event}`);
			}

			res.status(200).send("OK");
		} catch (error) {
			console.error("Error processing Razorpay webhook:", error);
			res.status(500).send("Internal Server Error");
		}
	},
);
