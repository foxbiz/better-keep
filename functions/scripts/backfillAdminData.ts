/**
 * Builds the backend-only admin user index, normalizes current subscription
 * fields, and backfills exact verified Razorpay revenue. Dry-run is default.
 *
 * Execute with ADC configured:
 *   npx tsx scripts/backfillAdminData.ts \
 *     --execute --project=better-keep-notes --database=better-keep
 */
import * as readline from "node:readline/promises";
import { applicationDefault } from "firebase-admin/app";
import { FieldValue } from "firebase-admin/firestore";
import { ADMIN_METRICS_COLLECTION, ADMIN_USER_COLLECTION } from "../src/adminConfig";
import { listIdentityToolkitUsers } from "../src/adminIdentityToolkitUsers";
import { canonicalSubscriptionFields } from "../src/adminSubscription";
import { adminUserIndexData } from "../src/adminUserIndex";
import { forEachBounded } from "../src/boundedConcurrency";
import { app, databaseId, db } from "../src/config";
import { minorUnitsToMicros } from "../src/revenueLedger";
import { enqueueRevenueEvent } from "../src/revenueOutbox";

const EXPECTED_PROJECT = "better-keep-notes";
const EXPECTED_DATABASE = "better-keep";
const USER_WRITE_CONCURRENCY = 25;

function argument(name: string): string | null {
	const prefix = `--${name}=`;
	return process.argv.find((value) => value.startsWith(prefix))?.slice(prefix.length) ?? null;
}

async function confirmTarget(): Promise<void> {
	if (!process.stdin.isTTY) throw new Error("Execution requires an interactive terminal");
	const prompt = readline.createInterface({ input: process.stdin, output: process.stdout });
	try {
		const expected = `${EXPECTED_PROJECT}/${EXPECTED_DATABASE}`;
		const answer = await prompt.question(`Type ${expected} to backfill admin data: `);
		if (answer.trim() !== expected) throw new Error("Target confirmation did not match");
	} finally {
		prompt.close();
	}
}

async function main(): Promise<void> {
	const execute = process.argv.includes("--execute");
	const resolvedProject = app.options.projectId ?? process.env.GOOGLE_CLOUD_PROJECT;
	if (execute) {
		if (
			argument("project") !== EXPECTED_PROJECT ||
			argument("database") !== EXPECTED_DATABASE ||
			resolvedProject !== EXPECTED_PROJECT ||
			databaseId !== EXPECTED_DATABASE
		) {
			throw new Error("Resolved and explicit Firebase targets must match production");
		}
		await confirmTarget();
	}

	console.log(`Mode: ${execute ? "EXECUTE" : "DRY RUN"}`);
	const credential = app.options.credential ?? applicationDefault();
	if (!resolvedProject) {
		throw new Error("Application Default Credentials and a Firebase project are required");
	}
	let pageToken: string | undefined;
	let userCount = 0;
	do {
		const page = await listIdentityToolkitUsers({
			credential,
			projectId: resolvedProject,
			pageToken,
		});
		userCount += page.users.length;
		if (execute) {
			await forEachBounded(page.users, USER_WRITE_CONCURRENCY, async (user) => {
				const userRef = db.collection("users").doc(user.uid);
				const [profile, subscription] = await Promise.all([
					userRef.get(),
					userRef.collection("subscription").doc("status").get(),
				]);
				await db.collection(ADMIN_USER_COLLECTION).doc(user.uid).set(
					adminUserIndexData({
						user,
						profile: profile.data(),
						subscription: subscription.data(),
					}),
					{ merge: false },
				);
				if (subscription.exists && subscription.data()) {
					await subscription.ref.set(canonicalSubscriptionFields(subscription.data() ?? {}), {
						merge: true,
					});
				}
			});
		}
		pageToken = page.pageToken;
	} while (pageToken);

	const verifiedPayments = await db.collection("payments").where("status", "==", "verified").get();
	let razorpayPayments = 0;
	for (const payment of verifiedPayments.docs) {
		const data = payment.data();
		if (
			typeof data.razorpayPaymentId !== "string" ||
			typeof data.amount !== "number" ||
			typeof data.currency !== "string"
		) continue;
		razorpayPayments += 1;
		if (execute) {
			const occurredAt = data.verifiedAt?.toDate?.() ?? data.createdAt?.toDate?.() ?? new Date();
			await enqueueRevenueEvent({
				provider: "razorpay",
				providerTransactionId: data.razorpayPaymentId,
				userId: typeof data.userId === "string" ? data.userId : null,
				amountMicros: minorUnitsToMicros(data.amount),
				currency: data.currency,
				kind: "charge",
				environment: "production",
				occurredAt,
				metadata: { paymentDocumentId: payment.id, plan: data.plan ?? null },
			});
		}
	}

	if (execute) {
		await db.collection(ADMIN_METRICS_COLLECTION).doc("current").set(
			{ totalUsers: userCount, totalUsersUpdatedAt: FieldValue.serverTimestamp() },
			{ merge: true },
		);
	}
	console.log(`Users discovered: ${userCount}`);
	console.log(`Verified Razorpay payments discovered: ${razorpayPayments}`);
	console.log(execute ? "Backfill complete." : "Dry run complete. No data changed.");
}

main().catch((error: unknown) => {
	console.error(error instanceof Error ? error.message : error);
	process.exitCode = 1;
});
