import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import {
	appStoreSharedSecret,
	googlePlayCredentials,
	IOS_PRODUCT_IDS,
	SUBSCRIPTION_PRODUCT_ID,
} from "../config";
import { verifyAppStorePurchase, verifyGooglePlayPurchase } from "../utils";

/**
 * Restore subscription from a purchase token (for app crash recovery)
 */
export default onCall(
	{ secrets: [googlePlayCredentials, appStoreSharedSecret] },
	async (
		request: CallableRequest<{
			purchaseToken: string;
			source?: "play_store" | "app_store";
			productId?: string;
		}>,
	) => {
		if (!request.auth) {
			throw new HttpsError("unauthenticated", "User must be signed in");
		}

		const userId = request.auth.uid;
		const { purchaseToken, source = "play_store", productId } = request.data;

		if (!purchaseToken) {
			throw new HttpsError("invalid-argument", "Purchase token is required");
		}

		console.log(`Attempting to restore subscription for user ${userId}`);

		try {
			const result =
				source === "app_store"
					? await verifyAppStorePurchase(
							userId,
							productId || IOS_PRODUCT_IDS.monthly,
							purchaseToken,
						)
					: await verifyGooglePlayPurchase(
							userId,
							SUBSCRIPTION_PRODUCT_ID,
							purchaseToken,
						);

			if (result.valid) {
				return {
					success: true,
					message: "Subscription restored successfully",
					subscription: result.subscription,
				};
			}

			return {
				success: false,
				message: result.message,
			};
		} catch (error) {
			console.error(`Error restoring subscription for ${userId}:`, error);

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to restore subscription");
		}
	},
);
