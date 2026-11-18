export type SubscriptionPlanClaim = "pro" | "lite" | "free";

/** Preserves unrelated security claims while updating subscription claims. */
export function mergeSubscriptionClaims(
	existingClaims: Record<string, unknown> | undefined,
	plan: SubscriptionPlanClaim,
	expiresAt: Date | null,
): Record<string, unknown> {
	return {
		...(existingClaims ?? {}),
		plan,
		planExpiresAt:
			plan !== "free" && expiresAt !== null ? expiresAt.getTime() : null,
	};
}
