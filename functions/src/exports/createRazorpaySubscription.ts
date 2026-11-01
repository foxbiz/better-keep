import { FieldValue } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import {
	DEFAULT_CURRENCY,
	db,
	razorpayKeyId,
	razorpayKeySecret,
	razorpayPlanConfig,
} from "../config";
import { onNonReviewCall } from "../nonReviewCallable";
import { evaluateSubscription } from "../subscriptionEntitlement";
import type { SupportedCurrency } from "../types";
import { razorpayRequest } from "../utils";

/**
 * Create a Razorpay subscription for the user
 * Called from web/desktop clients
 */
export default onNonReviewCall(
	{
		secrets: [razorpayKeyId, razorpayKeySecret],
		cors: true,
	},
	async (
		request: CallableRequest<{
			yearly: boolean;
			tier?: "lite" | "pro";
			currency?: SupportedCurrency;
		}>,
	) => {
		// Verify user is authenticated
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be authenticated");
		}
		const userId = request.auth.uid;
		const { yearly } = request.data;
		const tier = request.data.tier ?? "pro";
		if (tier !== "lite" && tier !== "pro")
			throw new HttpsError("invalid-argument", "Unknown plan");
		// Use provided currency or default to USD
		const currency: SupportedCurrency =
			request.data.currency === "INR" ? "INR" : DEFAULT_CURRENCY;
		const planType = yearly ? "yearly" : "monthly";
		const plan = razorpayPlanConfig(tier, currency, planType);

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

			const existing = evaluateSubscription(existingSubDoc.data());
			if (existing.entitled && existing.source !== "trial") {
				throw new HttpsError(
					"already-exists",
					"Manage your current subscription before changing plans.",
				);
			}

			const keyId = razorpayKeyId.value().trim();
			const keySecret = razorpayKeySecret.value().trim();

			// Get or create the plan for the selected currency
			const planId = await getOrCreateRazorpayPlan(
				keyId,
				keySecret,
				planType,
				currency,
				tier,
			);

			// Create a subscription
			// Razorpay limits total_count based on billing period:
			// - Monthly: max 100 cycles (about 8 years)
			// - Yearly: max 100 cycles (about 100 years)
			// Using conservative values to stay within limits
			const totalCount = yearly ? 30 : 100;

			const subscription = await razorpayRequest(
				keyId,
				keySecret,
				"POST",
				"/subscriptions",
				{
					plan_id: planId,
					total_count: totalCount,
					customer_notify: 1,
					notes: {
						userId: userId,
						plan: planType,
						tier,
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
				tier,
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
export async function getOrCreateRazorpayPlan(
	keyId: string,
	keySecret: string,
	planType: "monthly" | "yearly",
	currency: SupportedCurrency = DEFAULT_CURRENCY,
	tier: "lite" | "pro" = "pro",
	requestPlan: typeof razorpayRequest = razorpayRequest,
): Promise<string> {
	const planConfig = razorpayPlanConfig(tier, currency, planType);
	// v3: Multi-currency support - USD and INR (Dec 2025)
	const planName = `better_keep_${tier}_${planType}_${currency.toLowerCase()}_${tier === "pro" ? "v3" : "v1"}`;

	try {
		// Catalog plans are immutable. Check every page and fail closed if a
		// matching name has different billing terms rather than charging it.
		for (let skip = 0; ; skip += 100) {
			const page = (await requestPlan(
				keyId,
				keySecret,
				"GET",
				`/plans?count=100&skip=${skip}`,
			)) as {
				items: Array<{
					id: string;
					period: string;
					interval: number;
					item: { name: string; amount: number; currency: string };
				}>;
			};
			if (!Array.isArray(page.items)) {
				throw new HttpsError("unavailable", "Unable to read billing plans");
			}
			const existingPlan = page.items.find((p) => p.item?.name === planName);
			if (existingPlan) {
				if (
					existingPlan.period !== planType ||
					existingPlan.interval !== 1 ||
					existingPlan.item.amount !== planConfig.amount ||
					existingPlan.item.currency !== planConfig.currency
				) {
					throw new HttpsError(
						"failed-precondition",
						"Billing plan configuration does not match",
					);
				}
				return existingPlan.id;
			}
			if (page.items.length < 100) break;
			if (skip >= 9900) {
				throw new HttpsError(
					"unavailable",
					"Billing plan lookup limit reached",
				);
			}
		}

		// Create new plan
		console.log(`Creating new Razorpay plan: ${planName}`);
		const newPlan = (await requestPlan(keyId, keySecret, "POST", "/plans", {
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
