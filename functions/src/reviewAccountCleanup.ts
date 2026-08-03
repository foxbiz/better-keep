import * as crypto from "node:crypto";
import type { Bucket, File } from "@google-cloud/storage";
import type { DocumentReference, Firestore } from "firebase-admin/firestore";

export interface ReviewAccountCleanupResult {
	deletedSubscriptions: number;
	deletedPayments: number;
	deletedShares: number;
	deletedAccountLinkSessions: number;
	deletedOAuthStates: number;
	deletedOAuthCompletions: number;
	deletedUserStorageFiles: number;
	deletedShareStorageFiles: number;
}

interface ReviewAccountCleanupOptions {
	db: Firestore;
	bucket: Bucket;
	uid: string;
	email: string;
}

interface ReviewAccountCleanupPlan {
	result: ReviewAccountCleanupResult;
	userRef: DocumentReference;
	subscriptionRefs: DocumentReference[];
	paymentRefs: DocumentReference[];
	shareRefs: DocumentReference[];
	accountLinkSessionRefs: DocumentReference[];
	oauthStateRefs: DocumentReference[];
	oauthCompletionRefs: DocumentReference[];
	passwordResetRef: DocumentReference;
	trialUsageRef: DocumentReference;
	userFiles: File[];
	shareFiles: File[];
}

async function recursivelyDeleteDocuments(
	db: Firestore,
	documents: DocumentReference[],
): Promise<void> {
	await Promise.all(documents.map((document) => db.recursiveDelete(document)));
}

async function buildCleanupPlan({
	db,
	bucket,
	uid,
	email,
}: ReviewAccountCleanupOptions): Promise<ReviewAccountCleanupPlan> {
	const normalizedEmail = email.trim().toLowerCase();
	const passwordResetId = crypto
		.createHash("sha256")
		.update(normalizedEmail)
		.digest("hex");
	const [
		subscriptions,
		payments,
		shares,
		accountLinkSessions,
		oauthStates,
		oauthCompletions,
		[userFiles],
		[shareFiles],
	] = await Promise.all([
		db.collection("subscriptions").where("userId", "==", uid).get(),
		db.collection("payments").where("userId", "==", uid).get(),
		db.collection("shares").where("owner_uid", "==", uid).get(),
		db.collection("accountLinkSessions").where("uid", "==", uid).get(),
		db.collection("oauthStates").where("linkingUserId", "==", uid).get(),
		db.collection("oauthCompletions").where("uid", "==", uid).get(),
		bucket.getFiles({ prefix: `users/${uid}/` }),
		bucket.getFiles({ prefix: `shares/${uid}/` }),
	]);

	return {
		result: {
			deletedSubscriptions: subscriptions.size,
			deletedPayments: payments.size,
			deletedShares: shares.size,
			deletedAccountLinkSessions: accountLinkSessions.size,
			deletedOAuthStates: oauthStates.size,
			deletedOAuthCompletions: oauthCompletions.size,
			deletedUserStorageFiles: userFiles.length,
			deletedShareStorageFiles: shareFiles.length,
		},
		userRef: db.collection("users").doc(uid),
		subscriptionRefs: subscriptions.docs.map((document) => document.ref),
		paymentRefs: payments.docs.map((document) => document.ref),
		shareRefs: shares.docs.map((document) => document.ref),
		accountLinkSessionRefs: accountLinkSessions.docs.map(
			(document) => document.ref,
		),
		oauthStateRefs: oauthStates.docs.map((document) => document.ref),
		oauthCompletionRefs: oauthCompletions.docs.map((document) => document.ref),
		passwordResetRef: db.collection("passwordResetOtps").doc(passwordResetId),
		trialUsageRef: db.collection("trialUsage").doc(normalizedEmail),
		userFiles,
		shareFiles,
	};
}

export async function inspectReviewAccountData(
	options: ReviewAccountCleanupOptions,
): Promise<ReviewAccountCleanupResult> {
	return (await buildCleanupPlan(options)).result;
}

export async function cleanupReviewAccountData(
	options: ReviewAccountCleanupOptions,
): Promise<ReviewAccountCleanupResult> {
	const plan = await buildCleanupPlan(options);
	await Promise.all([
		options.db.recursiveDelete(plan.userRef),
		recursivelyDeleteDocuments(options.db, plan.subscriptionRefs),
		recursivelyDeleteDocuments(options.db, plan.paymentRefs),
		recursivelyDeleteDocuments(options.db, plan.shareRefs),
		recursivelyDeleteDocuments(options.db, plan.accountLinkSessionRefs),
		recursivelyDeleteDocuments(options.db, plan.oauthStateRefs),
		recursivelyDeleteDocuments(options.db, plan.oauthCompletionRefs),
		plan.passwordResetRef.delete(),
		plan.trialUsageRef.delete(),
		Promise.all(plan.userFiles.map((file) => file.delete())),
		Promise.all(plan.shareFiles.map((file) => file.delete())),
	]);
	return plan.result;
}
