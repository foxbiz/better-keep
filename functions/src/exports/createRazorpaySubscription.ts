import { FieldValue } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import {
	DEFAULT_CURRENCY,
	db,
	RAZORPAY_PLANS,
	razorpayKeyId,
	razorpayKeySecret,
} from "../config";
import type { SupportedCurrency } from "../types";
import { razorpayRequest } from "../utils";

/**
 * Create a Razorpay subscription for the user
 * Called from web/desktop clients
 */
export default onCall(
	{
		secrets: [razorpayKeyId, razorpayKeySecret],
		cors: true,
	},
	async (
		request: CallableRequest<{
			yearly: boolean;
			currency?: SupportedCurrency;
		}>,
	) => {
		// Verify user is authenticated
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}

		const userId = request.auth.uid;
		const { yearly } = request.data;
		// Use provided currency or default to USD
		const currency: SupportedCurrency =
			request.data.currency === "INR" ? "INR" : DEFAULT_CURRENCY;
		const planType = yearly ? "yearly" : "monthly";
		const plan = RAZORPAY_PLANS[currency][planType];

		console.log(
			`Creating Razorpay subscription for user ${userId}, yearly: ${yearly}, currency: ${currency}`,
		);

		try {
			// Check for existing active subscription
			const existingSubDoc = await db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status")
				.get();

			if (existingSubDoc.exists) {
				const existingSub = existingSubDoc.data();
				if (
					existingSub &&
					existingSub.plan !== "free" &&
					existingSub.subscriptionState === "SUBSCRIPTION_STATE_ACTIVE" &&
					existingSub.source !== "trial" && // Allow upgrade from trial
					existingSub.purchasePlatform !== "trial" // Allow upgrade from trial
				) {
					// Check if not expired
					const expiryDate = existingSub.expiryDate?.toDate?.();
					if (expiryDate && expiryDate > new Date()) {
						console.log(
							`User ${userId} already has an active subscription: ${existingSub.plan}`,
						);
						throw new HttpsError(
							"already-exists",
							"You already have an active subscription. Please cancel your current subscription first if you want to change plans.",
						);
					}
				}
			}

			const keyId = razorpayKeyId.value().trim();
			const keySecret = razorpayKeySecret.value().trim();

			// Get or create the plan for the selected currency
			const planId = await getOrCreateRazorpayPlan(
				keyId,
				keySecret,
				planType,
				currency,
			);

			// Create a subscription
			const subscription = await razorpayRequest(
				keyId,
				keySecret,
				"POST",
				"/subscriptions",
				{
					plan_id: planId,
					total_count: 120, // Max billing cycles
					quantity: 1,
					customer_notify: 1,
					notes: {
						userId: userId,
						plan: planType,
						currency: currency,
					},
				},
			);

			const subData = subscription as {
				id: string;
				short_url: string;
				status: string;
			};

			// Store pending payment in Firebase
			await db.collection("payments").doc(subData.id).set({
				userId,
				type: "subscription",
				plan: planType,
				amount: plan.amount,
				currency: plan.currency,
				razorpaySubscriptionId: subData.id,
				razorpayPlanId: planId,
				status: "created",
				createdAt: FieldValue.serverTimestamp(),
			});

			console.log(
				`Created Razorpay subscription ${subData.id} for user ${userId}`,
			);

			return {
				subscriptionId: subData.id,
				keyId: keyId,
				amount: plan.amount,
				currency: plan.currency,
				name: plan.name,
			};
		} catch (error) {
			console.error("Error creating Razorpay subscription:", error);
			// Re-throw HttpsError as-is, only wrap other errors
			if (error instanceof HttpsError) {
				throw error;
			}
			throw new HttpsError("internal", "Failed to create subscription");
		}
	},
);

/**
 * Get or create a Razorpay plan
 * Creates plan if it doesn't exist, returns existing plan ID otherwise
 */
async function getOrCreateRazorpayPlan(
	keyId: string,
	keySecret: string,
	planType: "monthly" | "yearly",
	currency: SupportedCurrency = DEFAULT_CURRENCY,
): Promise<string> {
	const planConfig = RAZORPAY_PLANS[currency][planType];
	// v3: Multi-currency support - USD and INR (Dec 2025)
	const planName = `better_keep_pro_${planType}_${currency.toLowerCase()}_v3`;

	try {
		// First, try to find existing plan by listing plans
		const plansResponse = (await razorpayRequest(
			keyId,
			keySecret,
			"GET",
			"/plans?count=100",
		)) as { items: Array<{ id: string; item: { name: string } }> };

		const existingPlan = plansResponse.items?.find(
			(p) => p.item?.name === planName,
		);

		if (existingPlan) {
			console.log(`Found existing Razorpay plan: ${existingPlan.id}`);
			return existingPlan.id;
		}

		// Create new plan
		console.log(`Creating new Razorpay plan: ${planName}`);
		const newPlan = (await razorpayRequest(keyId, keySecret, "POST", "/plans", {
			period: planType === "yearly" ? "yearly" : "monthly",
			interval: 1,
			item: {
				name: planName,
				amount: planConfig.amount,
				currency: planConfig.currency,
				description: planConfig.name,
			},
		})) as { id: string };

		console.log(`Created Razorpay plan: ${newPlan.id}`);
		return newPlan.id;
	} catch (error) {
		console.error(`Error getting/creating plan ${planType}:`, error);
		throw error;
	}
}
