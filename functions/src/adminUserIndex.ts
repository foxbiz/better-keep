import type { UserRecord } from "firebase-admin/auth";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import {
	ADMIN_ACCESS_CLAIM,
	ADMIN_USER_COLLECTION,
	configuredAdminUid,
} from "./adminConfig";
import { summarizeSubscription } from "./adminSubscription";
import { auth, db } from "./config";
import { REVIEW_ACCOUNT_EMAIL } from "./reviewConfig";

function authTimestamp(value: string | undefined): Timestamp | null {
	if (!value) return null;
	const date = new Date(value);
	return Number.isNaN(date.getTime()) ? null : Timestamp.fromDate(date);
}

function lower(value: string | null | undefined): string {
	return value?.trim().toLowerCase() ?? "";
}

export interface AdminIndexUserRecord {
	uid: string;
	email?: string;
	displayName?: string;
	photoURL?: string;
	providerData: Array<{ providerId: string }>;
	disabled: boolean;
	emailVerified: boolean;
	customClaims?: Record<string, unknown>;
	metadata: {
		creationTime?: string;
		lastSignInTime?: string;
	};
}

export function adminUserIndexData({
	user,
	profile,
	subscription,
	now = Date.now(),
}: {
	user: AdminIndexUserRecord;
	profile?: Record<string, unknown> | null;
	subscription?: Record<string, unknown> | null;
	now?: number;
}): Record<string, unknown> {
	const summary = summarizeSubscription(subscription, now);
	const displayName =
		user.displayName ??
		(typeof profile?.displayName === "string" ? profile.displayName : null);
	const email =
		user.email ?? (typeof profile?.email === "string" ? profile.email : null);

	return {
		uid: user.uid,
		email: email ?? null,
		emailLower: lower(email),
		displayName: displayName ?? null,
		displayNameLower: lower(displayName),
		photoURL: user.photoURL ?? null,
		providers: user.providerData.map((provider) => provider.providerId).sort(),
		disabled: user.disabled,
		emailVerified: user.emailVerified,
		isAdmin:
			user.uid === configuredAdminUid() &&
			user.customClaims?.[ADMIN_ACCESS_CLAIM] === true,
		isReviewAccount: lower(email) === REVIEW_ACCOUNT_EMAIL.toLowerCase(),
		authCreatedAt: authTimestamp(user.metadata.creationTime),
		lastSignInAt: authTimestamp(user.metadata.lastSignInTime),
		lastSeen: profile?.lastSeen instanceof Timestamp ? profile.lastSeen : null,
		plan: summary.plan,
		subscriptionClass: summary.subscriptionClass,
		renewalState: summary.renewalState,
		entitlementState: summary.entitlementState,
		subscriptionEnvironment: summary.environment,
		subscriptionSource: summary.source,
		subscriptionState: summary.state,
		billingPeriod: summary.billingPeriod,
		subscriptionExpiresAt: summary.expiresAt,
		updatedAt: FieldValue.serverTimestamp(),
	};
}

export async function syncAdminUserIndex(userId: string): Promise<void> {
	let user: UserRecord;
	try {
		user = await auth.getUser(userId);
	} catch (error) {
		if ((error as { code?: string }).code === "auth/user-not-found") {
			await db.collection(ADMIN_USER_COLLECTION).doc(userId).delete();
			return;
		}
		throw error;
	}

	const userRef = db.collection("users").doc(userId);
	const [profileSnap, subscriptionSnap] = await Promise.all([
		userRef.get(),
		userRef.collection("subscription").doc("status").get(),
	]);
	await db
		.collection(ADMIN_USER_COLLECTION)
		.doc(userId)
		.set(
			adminUserIndexData({
				user,
				profile: profileSnap.data(),
				subscription: subscriptionSnap.data(),
			}),
			{ merge: false },
		);
}
