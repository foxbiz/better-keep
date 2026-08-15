export const ADMIN_ACCESS_CLAIM = "appAdmin";
export const ADMIN_TOTP_FACTOR = "totp";
export const ADMIN_RECENT_AUTH_SECONDS = 15 * 60;

export function configuredAdminUid(): string {
	return process.env.ADMIN_ACCOUNT_UID?.trim() ?? "";
}

export const ADMIN_USER_COLLECTION = "adminUsers";
export const ADMIN_AUDIT_COLLECTION = "adminAuditLogs";
export const ADMIN_BILLING_ACTIVITY_COLLECTION = "adminBillingActivities";
export const ADMIN_METRICS_COLLECTION = "adminMetrics";
export const ADMIN_REVENUE_COLLECTION = "adminRevenueTransactions";
export const ADMIN_REVENUE_SUMMARY_COLLECTION = "adminRevenueSummary";
export const ADMIN_REVENUE_EVENT_COLLECTION = "adminRevenueEvents";
export const ADMIN_SUBSCRIPTION_ISSUE_COLLECTION = "adminSubscriptionIssues";
export const PLAY_STORE_EVENT_COLLECTION = "playStoreWebhookEvents";

export const PAID_SUBSCRIPTION_SOURCES = [
	"app_store",
	"play_store",
	"razorpay",
] as const;

export type PaidSubscriptionSource = (typeof PAID_SUBSCRIPTION_SOURCES)[number];
