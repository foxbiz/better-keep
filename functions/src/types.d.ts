// Supported currencies for Razorpay
export type SupportedCurrency = "USD" | "INR";

/**
 * Configuration for OTP email template
 */
export interface OtpEmailConfig {
	/** Title displayed at the top of the email */
	title: string;
	/** Main description text */
	description: string;
	/** The 6-digit OTP code */
	otp: string;
	/** Theme color - 'primary' (purple), 'warning' (orange), or 'danger' (red) */
	theme: "primary" | "warning" | "danger";
	/** Optional security warning message */
	securityNote?: string;
	/** Minutes until expiry (default: 10) */
	expiresInMinutes?: number;
}

// Subscription plans
export interface SubscriptionPlan {
	basePlanId: string;
	displayName: string;
	periodDays: number;
}

/**
 * Configuration for OTP email template
 */
export interface OtpEmailConfig {
	/** Title displayed at the top of the email */
	title: string;
	/** Main description text */
	description: string;
	/** The 6-digit OTP code */
	otp: string;
	/** Theme color - 'primary' (purple), 'warning' (orange), or 'danger' (red) */
	theme: "primary" | "warning" | "danger";
	/** Optional security warning message */
	securityNote?: string;
	/** Minutes until expiry (default: 10) */
	expiresInMinutes?: number;
}

export interface VerifyPurchaseRequest {
	/**
	 * Android: Google Play purchase token.
	 * iOS: base64 App Store app receipt expected by verifyReceipt endpoint.
	 */
	productId: string;
	purchaseToken: string;
	source: "play_store" | "app_store";
	/** Optional client-provided correlation id for end-to-end purchase verification logging. */
	verifyTraceId?: string;
}

export interface CheckSubscriptionRequest {
	purchaseToken?: string;
}

/**
 * Decoded payload from an App Store StoreKit 2 JWS signed transaction.
 * @see https://developer.apple.com/documentation/appstoreserverapi/jwstransactiondecodedpayload
 */
export interface AppStoreJWSTransactionPayload {
	transactionId: string;
	originalTransactionId: string;
	productId: string;
	bundleId: string;
	/** Milliseconds since epoch */
	expiresDate: number;
	/** Milliseconds since epoch */
	signedDate: number;
	environment: "Sandbox" | "Production";
	type:
		| "Auto-Renewable Subscription"
		| "Non-Consumable"
		| "Consumable"
		| "Non-Renewing Subscription";
	inAppOwnershipType: "PURCHASED" | "FAMILY_SHARED";
	/** Milliseconds since epoch, present only if revoked */
	revocationDate?: number;
}
