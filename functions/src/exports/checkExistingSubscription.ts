import type * as admin from "firebase-admin";
import { FieldValue } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { ANDROID_PACKAGE_NAME, db, googlePlayCredentials } from "../config";
import type { CheckSubscriptionRequest } from "../types";
import { getPlayDeveloperApi } from "../utils";

/**
 * Check if user already has an active subscription before making a new purchase.
 * Also attempts to recover/restore any existing subscription.
 */
export default onCall(
	{ secrets: [googlePlayCredentials] },
	async (request: CallableRequest<CheckSubscriptionRequest>) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be signed in");
		}

		const userId = request.auth.uid;
		console.log(`Checking existing subscription for user ${userId}`);

		try {
			// Check user's current subscription status in Firestore
			const userSubRef = db
				.collection("users")
				.doc(userId)
				.collection("subscription")
				.doc("status");

			const userSubDoc = await userSubRef.get();

			if (userSubDoc.exists) {
				const subData = userSubDoc.data();
				if (!subData) return { hasSubscription: false };

				// If user is on a trial, allow them to purchase a paid subscription
				// Check both 'source' (used by grantTrialOnFirstSignIn) and 'purchasePlatform' (used elsewhere)
				const isTrial =
					subData.source === "trial" || subData.purchasePlatform === "trial";
				if (isTrial) {
					console.log(
						`User ${userId} is on trial (source: ${subData.source}, purchasePlatform: ${subData.purchasePlatform}), allowing upgrade`,
					);
					return { hasSubscription: false, isTrial: true };
				}

				// Support both field names: expiresAt (Play Store) and expiryDate (Razorpay)
				const expiresAt =
					subData.expiresAt?.toDate() || subData.expiryDate?.toDate();

				// If subscription exists and not expired
				if (expiresAt && expiresAt > new Date()) {
					console.log(
						`User ${userId} has active subscription until ${expiresAt}`,
					);

					// Optionally verify with Google Play if we have a token
					if (subData.purchaseToken && subData.source === "play_store") {
						try {
							const playApi = await getPlayDeveloperApi(
								googlePlayCredentials.value(),
							);
							const response = await playApi.purchases.subscriptionsv2.get({
								packageName: ANDROID_PACKAGE_NAME,
								token: subData.purchaseToken,
							});

							const subscriptionState = response.data.subscriptionState;
							const isActive =
								subscriptionState === "SUBSCRIPTION_STATE_ACTIVE" ||
								subscriptionState === "SUBSCRIPTION_STATE_IN_GRACE_PERIOD";

							console.log(
								`Subscription state on Google for user ${userId}: ${subscriptionState}`,
							);

							if (!isActive) {
								// Subscription was cancelled or expired on Google's side
								// Check if it's a terminal state (cancelled, expired, revoked)
								const isTerminal =
									subscriptionState === "SUBSCRIPTION_STATE_CANCELED" ||
									subscriptionState === "SUBSCRIPTION_STATE_EXPIRED";

								if (isTerminal) {
									// Delete the subscription document - user is now on free plan
									console.log(
										`Subscription is terminal (${subscriptionState}), removing from user`,
									);
									await userSubRef.delete();
									return {
										hasSubscription: false,
										message: "Subscription has been cancelled or expired",
									};
								} else {
									// Just update the status (e.g., paused, pending)
									await userSubRef.update({
										willAutoRenew: false,
										subscriptionState,
										updatedAt: FieldValue.serverTimestamp(),
									});
								}
							}

							return {
								hasSubscription: isActive,
								subscription: {
									plan: subData.plan,
									billingPeriod: subData.billingPeriod,
									expiresAt: expiresAt.toISOString(),
									willAutoRenew:
										isActive &&
										subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
									source: subData.source,
								},
							};
						} catch (verifyError) {
							console.warn("Failed to verify with Google Play:", verifyError);
							// Fall back to local data
						}
					}

					return {
						hasSubscription: true,
						subscription: {
							plan: subData.plan,
							billingPeriod: subData.billingPeriod,
							expiresAt: expiresAt.toISOString(),
							willAutoRenew: subData.willAutoRenew ?? subData.autoRenew,
							source: subData.source,
						},
					};
				}
			}

			// Check if there's a subscription linked to this user in global subscriptions
			// Note: We query without orderBy to avoid needing a composite index.
			// For users with multiple subscriptions, we check all and use the one with the latest expiry.
			const linkedSubs = await db
				.collection("subscriptions")
				.where("userId", "==", userId)
				.get();

			if (!linkedSubs.empty) {
				// Find the subscription with the latest expiry date
				let latestSub: admin.firestore.QueryDocumentSnapshot | null = null;
				let latestExpiry: Date | null = null;

				for (const doc of linkedSubs.docs) {
					const subData = doc.data();
					const expiresAt = subData.expiresAt?.toDate();
					if (expiresAt && (!latestExpiry || expiresAt > latestExpiry)) {
						latestExpiry = expiresAt;
						latestSub = doc;
					}
				}

				if (latestSub && latestExpiry && latestExpiry > new Date()) {
					const subData = latestSub.data();
					// Found an active subscription - restore it
					console.log(`Restoring subscription for user ${userId}`);

					await userSubRef.set({
						plan: "pro",
						billingPeriod:
							subData.basePlanId === "pro-yearly" ? "yearly" : "monthly",
						expiresAt: subData.expiresAt,
						willAutoRenew:
							subData.subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
						purchaseToken: subData.purchaseToken,
						source: subData.source,
						basePlanId: subData.basePlanId,
						restoredAt: FieldValue.serverTimestamp(),
						updatedAt: FieldValue.serverTimestamp(),
					});

					return {
						hasSubscription: true,
						restored: true,
						subscription: {
							plan: "pro",
							billingPeriod:
								subData.basePlanId === "pro-yearly" ? "yearly" : "monthly",
							expiresAt: latestExpiry.toISOString(),
							willAutoRenew:
								subData.subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
							source: subData.source,
						},
					};
				}
			}

			// No active subscription found
			return {
				hasSubscription: false,
			};
		} catch (error) {
			console.error(`Error checking subscription for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to check subscription status");
		}
	},
);
