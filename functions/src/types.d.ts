import type { ALLOWED_PROVIDERS } from "./config";

// Supported currencies for Razorpay
export type SupportedCurrency = "USD" | "INR";
export type AllowedProvider = (typeof ALLOWED_PROVIDERS)[number];

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

export interface OAuthState {
	provider: string;
	redirect: string;
	nonce?: string;
	mode?: "signin" | "link";
	linkingUserId?: string;
}

export interface VerifyPurchaseRequest {
	productId: string;
	purchaseToken: string;
	source: "play_store" | "app_store";
}

export interface CheckSubscriptionRequest {
	purchaseToken?: string;
}
