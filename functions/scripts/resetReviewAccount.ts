/**
 * Local admin script to reset the review account before each app store review.
 *
 * Usage:
 *   cd functions
 *   npx tsx scripts/resetReviewAccount.ts <password>
 *
 * What it does:
 *   - Creates the review account if it doesn't exist, or resets it
 *   - Sets the password to the supplied value
 *   - Sets emailVerified: true
 *   - Deletes all notes, files, devices, approval requests, recovery key, OTPs
 *   - Grants a fresh trial subscription
 *   - Resets trial usage so grantTrialOnFirstSignIn works on next sign-in
 *
 * Prerequisites:
 *   - GOOGLE_APPLICATION_CREDENTIALS env var set, or run from a machine with
 *     Firebase default credentials (e.g. after `firebase login`)
 *   - Alternatively, set FIREBASE_PROJECT_ID env var
 */

import * as admin from "firebase-admin";

// Keep in sync with REVIEW_ACCOUNT_EMAIL in src/config.ts
const REVIEW_ACCOUNT_EMAIL = "review@betterkeep.app";
const TRIAL_DAYS = 30;

const password = process.argv[2];
if (!password || password.length < 6) {
	console.error("Usage: npx tsx scripts/resetReviewAccount.ts <password>");
	console.error("Password must be at least 6 characters.");
	process.exit(1);
}

const app = admin.initializeApp({
	projectId: "better-keep-notes",
	storageBucket: "better-keep-notes.firebasestorage.app",
});

// Use the named database in production, default in emulator
const isEmulator = process.env.FUNCTIONS_EMULATOR === "true";
const databaseId = isEmulator ? "(default)" : "better-keep";
const db = admin.firestore(app);
db.settings({ databaseId });
const auth = admin.auth();
const storage = admin.storage();

async function main() {
	console.log(`Resetting review account: ${REVIEW_ACCOUNT_EMAIL}`);

	// Find or create the review account
	let uid: string;
	try {
		const user = await auth.getUserByEmail(REVIEW_ACCOUNT_EMAIL);
		uid = user.uid;
		console.log(`Found existing account: ${uid}`);
	} catch {
		const user = await auth.createUser({
			email: REVIEW_ACCOUNT_EMAIL,
			password,
			emailVerified: true,
		});
		uid = user.uid;
		console.log(`Created new account: ${uid}`);
	}

	// Reset password and ensure emailVerified
	await auth.updateUser(uid, { password, emailVerified: true });
	console.log("Password reset and emailVerified set to true");

	const userRef = db.collection("users").doc(uid);

	// Delete all notes
	const notesSnapshot = await userRef.collection("notes").get();
	if (!notesSnapshot.empty) {
		const batchSize = 400;
		for (let i = 0; i < notesSnapshot.docs.length; i += batchSize) {
			const batch = db.batch();
			for (const doc of notesSnapshot.docs.slice(i, i + batchSize)) {
				batch.delete(doc.ref);
			}
			await batch.commit();
		}
	}
	console.log(`Deleted ${notesSnapshot.size} notes`);

	// Delete all storage files
	try {
		const bucket = storage.bucket();
		const [files] = await bucket.getFiles({ prefix: `users/${uid}/` });
		for (const file of files) {
			await file.delete();
		}
		console.log(`Deleted ${files.length} storage files`);
	} catch (e) {
		console.warn("Storage deletion issue:", e);
	}

	// Delete all devices
	const devicesSnapshot = await userRef.collection("devices").get();
	if (!devicesSnapshot.empty) {
		const batch = db.batch();
		for (const doc of devicesSnapshot.docs) batch.delete(doc.ref);
		await batch.commit();
	}
	console.log(`Deleted ${devicesSnapshot.size} devices`);

	// Delete pending approval requests
	const approvalsSnapshot = await userRef.collection("approvalRequests").get();
	if (!approvalsSnapshot.empty) {
		const batch = db.batch();
		for (const doc of approvalsSnapshot.docs) batch.delete(doc.ref);
		await batch.commit();
	}

	// Clear recovery key
	await userRef
		.collection("e2ee")
		.doc("recovery_key")
		.delete()
		.catch(() => {});

	// Clear OTP docs
	const otpSnapshot = await userRef.collection("otpVerification").get();
	if (!otpSnapshot.empty) {
		const batch = db.batch();
		for (const doc of otpSnapshot.docs) batch.delete(doc.ref);
		await batch.commit();
	}

	// Grant fresh trial subscription
	const trialExpiresAt = new Date();
	trialExpiresAt.setDate(trialExpiresAt.getDate() + TRIAL_DAYS);

	await userRef
		.collection("subscription")
		.doc("status")
		.set({
			plan: "pro",
			source: "trial",
			expiresAt: admin.firestore.Timestamp.fromDate(trialExpiresAt),
			billingPeriod: "trial",
			willAutoRenew: false,
			trialStartedAt: admin.firestore.Timestamp.now(),
			updatedAt: admin.firestore.Timestamp.now(),
		});

	// Set custom claims for pro access
	await auth.setCustomUserClaims(uid, {
		plan: "pro",
		planExpiresAt: trialExpiresAt.getTime(),
	});

	// Ensure user document exists
	await userRef.set(
		{
			email: REVIEW_ACCOUNT_EMAIL,
			createdAt: admin.firestore.Timestamp.now(),
			lastSeen: admin.firestore.Timestamp.now(),
		},
		{ merge: true },
	);

	// Reset trial usage so grantTrialOnFirstSignIn works on next sign-in
	await db
		.collection("trialUsage")
		.doc(REVIEW_ACCOUNT_EMAIL)
		.delete()
		.catch(() => {});

	// biome-ignore lint/style/noUnusedTemplateLiteral: <explanation>
	console.log(`\nReview account fully reset!`);
	console.log(`  Email:    ${REVIEW_ACCOUNT_EMAIL}`);
	console.log(`  Password: ${password}`);
	console.log(`  Trial:    expires ${trialExpiresAt.toISOString()}`);
	process.exit(0);
}

main().catch((e) => {
	console.error("Failed to reset review account:", e);
	process.exit(1);
});
