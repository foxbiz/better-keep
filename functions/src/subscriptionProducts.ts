export type PaidPlan = "lite" | "pro";
export type PlanPeriod = "monthly" | "yearly";

const APPLE_PRODUCTS: Record<string, { plan: PaidPlan; period: PlanPeriod }> = {
	pro_monthly: { plan: "pro", period: "monthly" },
	pro_yearly: { plan: "pro", period: "yearly" },
	lite_monthly: { plan: "lite", period: "monthly" },
	lite_yearly: { plan: "lite", period: "yearly" },
};

export function appleSubscriptionProduct(productId: string) {
	return Object.keys(APPLE_PRODUCTS).includes(productId)
		? APPLE_PRODUCTS[productId]
		: null;
}

export function playSubscriptionProduct(productId: string, basePlanId: string) {
	const plan =
		productId === "better_keep_pro"
			? "pro"
			: productId === "better_keep_lite"
				? "lite"
				: null;
	if (!plan || ![`${plan}-monthly`, `${plan}-yearly`].includes(basePlanId))
		return null;
	return {
		plan,
		period: basePlanId.endsWith("-yearly") ? "yearly" : "monthly",
	} as {
		plan: PaidPlan;
		period: PlanPeriod;
	};
}
