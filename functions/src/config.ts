import * as admin from "firebase-admin";
import { getFirestore } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import type { SubscriptionPlan, SupportedCurrency } from "./types";

export const app = admin.initializeApp();

// Check if running in emulator - emulator only supports default database
export const isEmulator = process.env.FUNCTIONS_EMULATOR === "true";
export const databaseId = isEmulator ? "(default)" : "better-keep";

// Use the named database 'better-keep' in production, default in emulator
export const db = getFirestore(app, databaseId);

export const auth = admin.auth();
export const storage = admin.storage();
export const emailPassword = defineSecret("EMAIL_PASSWORD");
// Google Play API credentials (service account JSON as base64 or JSON string)
export const googlePlayCredentials = defineSecret("GOOGLE_PLAY_CREDENTIALS");

// Razorpay API credentials
export const razorpayKeyId = defineSecret("RAZORPAY_KEY_ID");
export const razorpayKeySecret = defineSecret("RAZORPAY_KEY_SECRET");

// OAuth secrets for direct OAuth flow (bypasses Firebase SDK storage issues)
export const facebookAppId = defineSecret("FACEBOOK_APP_ID");
export const facebookAppSecret = defineSecret("FACEBOOK_APP_SECRET");
export const githubClientId = defineSecret("GITHUB_CLIENT_ID");
export const githubClientSecret = defineSecret("GITHUB_CLIENT_SECRET");
export const twitterClientId = defineSecret("TWITTER_CLIENT_ID");
export const twitterClientSecret = defineSecret("TWITTER_CLIENT_SECRET");

// Razorpay pricing by currency
// USD: amounts in cents (100 cents = $1)
// INR: amounts in paise (100 paise = ₹1)
export const RAZORPAY_PLANS: Record<
	SupportedCurrency,
	{
		monthly: {
			amount: number;
			currency: string;
			period: string;
			interval: number;
			name: string;
		};
		yearly: {
			amount: number;
			currency: string;
			period: string;
			interval: number;
			name: string;
		};
	}
> = {
	USD: {
		monthly: {
			amount: 299, // $2.99
			currency: "USD",
			period: "monthly",
			interval: 1,
			name: "Better Keep Pro Monthly",
		},
		yearly: {
			amount: 1999, // $19.99
			currency: "USD",
			period: "yearly",
			interval: 1,
			name: "Better Keep Pro Yearly",
		},
	},
	INR: {
		monthly: {
			amount: 23000, // ₹230
			currency: "INR",
			period: "monthly",
			interval: 1,
			name: "Better Keep Pro Monthly",
		},
		yearly: {
			amount: 162500, // ₹1625
			currency: "INR",
			period: "yearly",
			interval: 1,
			name: "Better Keep Pro Yearly",
		},
	},
};

// Default currency for Razorpay
// NOTE: Razorpay Subscriptions API only supports INR for most Indian merchants.
// USD subscriptions require special approval from Razorpay.
// Set to INR as default until multi-currency subscriptions are approved.
export const DEFAULT_CURRENCY: SupportedCurrency = "USD";

// Constants for subscription
export const ANDROID_PACKAGE_NAME = "io.foxbiz.better_keep";
export const SUBSCRIPTION_PRODUCT_ID = "better_keep_pro";

export const SUBSCRIPTION_PLANS: Record<string, SubscriptionPlan> = {
	"pro-monthly": {
		basePlanId: "pro-monthly",
		displayName: "Pro Monthly",
		periodDays: 30,
	},
	"pro-yearly": {
		basePlanId: "pro-yearly",
		displayName: "Pro Yearly",
		periodDays: 365,
	},
};

// Trial configuration (can be controlled via environment variables)
export const TRIAL_ENABLED = process.env.TRIAL_ENABLED === "true";
export const TRIAL_DAYS = parseInt(process.env.TRIAL_DAYS || "7", 10);
// Debug mode: use minutes instead of days for testing (only in emulator)
export const DEBUG_TRIAL_MINUTES =
	isEmulator && process.env.DEBUG_TRIAL_MINUTES
		? parseInt(process.env.DEBUG_TRIAL_MINUTES, 10)
		: null;

/**
 * Allowed provider IDs for account linking
 */
export const ALLOWED_PROVIDERS = [
	"google.com",
	"facebook.com",
	"github.com",
	"twitter.com",
] as const;
