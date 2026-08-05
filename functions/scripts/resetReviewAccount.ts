/**
 * Idempotently prepares the managed Google Play review account.
 *
 * Dry-run is the default:
 *   npx tsx scripts/resetReviewAccount.ts
 *
 * Production execution requires explicit targets, ADC and confirmation:
 *   npx tsx scripts/resetReviewAccount.ts \
 *     --execute --project=better-keep-notes --database=better-keep
 */

import * as fs from "node:fs";
import * as readline from "node:readline/promises";
import * as admin from "firebase-admin";
import { getFirestore } from "firebase-admin/firestore";
import {
	REVIEW_ACCESS_CLAIM,
	REVIEW_ACCOUNT_EMAIL,
} from "../src/reviewConfig";
import {
	cleanupReviewAccountData,
	inspectReviewAccountData,
	type ReviewAccountCleanupResult,
} from "../src/reviewAccountCleanup";
import {
	executeReviewAccountReset,
	type ReviewResetIdentity,
} from "../src/reviewAccountReset";
import {
	resolveReviewResetTarget,
	REVIEW_RESET_DATABASE_ID,
	REVIEW_RESET_PROJECT_ID,
} from "../src/reviewResetPolicy";

const REVIEW_ENTITLEMENT_DAYS = 3650;

function emptyCleanup(): ReviewAccountCleanupResult {
	return {
		deletedSubscriptions: 0,
		deletedPayments: 0,
		deletedShares: 0,
		deletedAccountLinkSessions: 0,
		deletedOAuthStates: 0,
		deletedOAuthCompletions: 0,
		deletedUserStorageFiles: 0,
		deletedShareStorageFiles: 0,
	};
}

function printCleanup(label: string, cleanup: ReviewAccountCleanupResult): void {
	console.log(label);
	console.log(`  Linked subscriptions: ${cleanup.deletedSubscriptions}`);
	console.log(`  Payment records: ${cleanup.deletedPayments}`);
	console.log(`  Owned shares: ${cleanup.deletedShares}`);
	console.log(`  Account-link sessions: ${cleanup.deletedAccountLinkSessions}`);
	console.log(`  Legacy OAuth states: ${cleanup.deletedOAuthStates}`);
	console.log(`  OAuth completions: ${cleanup.deletedOAuthCompletions}`);
	console.log(`  User storage files: ${cleanup.deletedUserStorageFiles}`);
	console.log(`  Share storage files: ${cleanup.deletedShareStorageFiles}`);
}

function resetIdentity(user: admin.auth.UserRecord): ReviewResetIdentity {
	return {
		uid: user.uid,
		providerIds: user.providerData.map((provider) => provider.providerId),
	};
}

async function confirmProductionTarget(): Promise<void> {
	if (!process.stdin.isTTY) {
		throw new Error("Production execution requires an interactive terminal");
	}
	const prompt = readline.createInterface({
		input: process.stdin,
		output: process.stdout,
	});
	try {
		const expected = `${REVIEW_RESET_PROJECT_ID}/${REVIEW_RESET_DATABASE_ID}`;
		const answer = await prompt.question(
			`Type ${expected} to execute the review reset: `,
		);
		if (answer.trim() !== expected) {
			throw new Error("Target confirmation did not match");
		}
	} finally {
		prompt.close();
	}
}

async function main(): Promise<void> {
	const execute = process.argv.includes("--execute");
	const target = resolveReviewResetTarget({
		execute,
		arguments: process.argv.slice(2),
		environment: process.env,
		loadCredentialProjectId: (credentialPath) => {
			const credential = JSON.parse(
				fs.readFileSync(credentialPath, "utf8"),
			) as { project_id?: string };
			return credential.project_id;
		},
	});
	const { isEmulator, databaseId } = target;
	const password = process.env.REVIEW_ACCOUNT_PASSWORD;
	if (execute && (!password || password.length < 12)) {
		throw new Error(
			"REVIEW_ACCOUNT_PASSWORD must be set and contain at least 12 characters",
		);
	}

	console.log(`Mode: ${execute ? "EXECUTE" : "DRY RUN"}`);
	console.log(`Project: ${target.projectId}`);
	console.log(`Database: ${databaseId}`);
	console.log(`Bucket: ${target.storageBucket}`);
	console.log(`Environment: ${isEmulator ? "emulator" : "production"}`);

	if (execute && !isEmulator) {
		await confirmProductionTarget();
	}

	const app = admin.initializeApp({
		projectId: target.projectId,
		storageBucket: target.storageBucket,
	});
	const db = getFirestore(app, databaseId);
	const auth = admin.auth(app);
	const bucket = admin.storage(app).bucket(target.storageBucket);
	if (bucket.name !== target.storageBucket) {
		throw new Error("Resolved Storage bucket does not match the target");
	}

	let existingUser: admin.auth.UserRecord | null = null;
	try {
		existingUser = await auth.getUserByEmail(REVIEW_ACCOUNT_EMAIL);
	} catch (error: unknown) {
		if ((error as { code?: string }).code !== "auth/user-not-found") {
			throw error;
		}
	}

	const preview = existingUser
		? await inspectReviewAccountData({
				db,
				bucket,
				uid: existingUser.uid,
				email: REVIEW_ACCOUNT_EMAIL,
			})
		: emptyCleanup();
	printCleanup("Planned cleanup:", preview);
	console.log(
		existingUser
			? `Existing review UID will be retained: ${existingUser.uid}`
			: "A disabled review identity will be created before preparation",
	);

	if (!execute) {
		console.log("Dry run complete. No data or authentication state changed.");
		return;
	}

	const entitlementExpiresAt = new Date();
	entitlementExpiresAt.setDate(
		entitlementExpiresAt.getDate() + REVIEW_ENTITLEMENT_DAYS,
	);
	try {
		const result = await executeReviewAccountReset({
			existingIdentity: existingUser ? resetIdentity(existingUser) : null,
			revokeSessions: (uid) => auth.revokeRefreshTokens(uid),
			disableIdentity: async (uid) =>
				resetIdentity(await auth.updateUser(uid, { disabled: true })),
			createDisabledIdentity: async () =>
				resetIdentity(
					await auth.createUser({
						email: REVIEW_ACCOUNT_EMAIL,
						password: password as string,
						emailVerified: true,
						disabled: true,
					}),
				),
			cleanup: (identity) =>
				cleanupReviewAccountData({
					db,
					bucket,
					uid: identity.uid,
					email: REVIEW_ACCOUNT_EMAIL,
				}),
			resetAuthentication: async (identity) => {
				const providersToUnlink = identity.providerIds.filter(
					(providerId) => providerId !== "password",
				);
				await auth.updateUser(identity.uid, {
					password: password as string,
					emailVerified: true,
					disabled: true,
					...(providersToUnlink.length > 0
						? { providersToUnlink }
						: {}),
				});
			},
			restoreEntitlement: async (uid) => {
				const now = admin.firestore.Timestamp.now();
				const userRef = db.collection("users").doc(uid);
				await userRef.set({
					email: REVIEW_ACCOUNT_EMAIL,
					createdAt: now,
					lastSeen: now,
				});
				await userRef.collection("subscription").doc("status").set({
					plan: "pro",
					source: "review",
					expiresAt:
						admin.firestore.Timestamp.fromDate(entitlementExpiresAt),
					billingPeriod: "review",
					willAutoRenew: false,
					trialStartedAt: now,
					updatedAt: now,
				});
			},
			restoreClaims: (uid) =>
				auth.setCustomUserClaims(uid, {
					[REVIEW_ACCESS_CLAIM]: true,
					plan: "pro",
					planExpiresAt: entitlementExpiresAt.getTime(),
				}),
			enableIdentity: async (uid) => {
				await auth.updateUser(uid, { disabled: false });
			},
		});

		printCleanup("Completed cleanup:", result.cleanup);
		console.log(`Review UID: ${result.uid}`);
		console.log(
			`Review entitlement expires: ${entitlementExpiresAt.toISOString()}`,
		);
		console.log("Review account prepared; the password was not printed.");
	} catch (error) {
		console.error(
			"Review reset failed. The review identity remains disabled; rerun the same command after correcting the error.",
		);
		throw error;
	}
}

main()
	.then(() => process.exit(0))
	.catch((error: unknown) => {
		console.error(
			"Failed to prepare review account:",
			error instanceof Error ? error.message : error,
		);
		process.exit(1);
	});
