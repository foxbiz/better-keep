import { Timestamp } from "firebase-admin/firestore";
import {
	auth,
	DEBUG_TRIAL_MINUTES,
	db,
	TRIAL_DAYS,
	TRIAL_ENABLED,
} from "./config";
import { mergeSubscriptionClaims } from "./customClaims";
import { sendTrialWelcomeEmail } from "./utils";

export interface TrialUser {
	uid: string;
	email?: string | null;
	displayName?: string | null;
	photoURL?: string | null;
	customClaims?: Record<string, unknown>;
}

export async function grantTrialIfEligible({
	user,
	persistCustomClaims,
}: {
	user: TrialUser;
	persistCustomClaims: boolean;
}): Promise<{ customClaims?: Record<string, unknown> }> {
	if (!TRIAL_ENABLED) return {};

	const email = user.email?.trim().toLowerCase() || null;
	const emailKey = email || `no-email-${user.uid}`;
	const userRef = db.collection("users").doc(user.uid);
	const subscriptionRef = userRef.collection("subscription").doc("status");
	const trialRef = db.collection("trialUsage").doc(emailKey);
	const trialExpiresAt = new Date();
	if (DEBUG_TRIAL_MINUTES !== null) {
		trialExpiresAt.setMinutes(
			trialExpiresAt.getMinutes() + DEBUG_TRIAL_MINUTES,
		);
	} else {
		trialExpiresAt.setDate(trialExpiresAt.getDate() + TRIAL_DAYS);
	}

	const granted = await db.runTransaction(async (transaction) => {
		const [existingSubscription, trialUsage] = await Promise.all([
			transaction.get(subscriptionRef),
			transaction.get(trialRef),
		]);
		if (existingSubscription.exists || trialUsage.exists) return false;

		const now = Timestamp.now();
		const expiry = Timestamp.fromDate(trialExpiresAt);
		transaction.set(trialRef, {
			userId: user.uid,
			email: email || "none",
			trialStartedAt: now,
			trialExpiresAt: expiry,
			createdAt: now,
		});
		transaction.set(
			userRef,
			{
				email,
				displayName: user.displayName || null,
				photoURL: user.photoURL || null,
				createdAt: now,
				lastSeen: now,
			},
			{ merge: true },
		);
		transaction.set(subscriptionRef, {
			plan: "pro",
			source: "trial",
			expiresAt: expiry,
			billingPeriod: "trial",
			willAutoRenew: false,
			trialStartedAt: now,
			updatedAt: now,
		});
		return true;
	});

	if (!granted) return {};
	const customClaims = mergeSubscriptionClaims(
		user.customClaims,
		"pro",
		trialExpiresAt,
	);
	if (persistCustomClaims) {
		await auth.setCustomUserClaims(user.uid, customClaims);
	}
	if (email) {
		sendTrialWelcomeEmail(
			email,
			user.displayName || "there",
			trialExpiresAt,
		).catch((error) => console.error("Trial welcome email failed", error));
	}
	return { customClaims };
}
