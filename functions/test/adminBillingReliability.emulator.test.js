const assert = require("node:assert/strict");
const test = require("node:test");
const { FieldPath, Timestamp } = require("firebase-admin/firestore");

process.env.FUNCTIONS_EMULATOR = "true";
const { auth, db } = require("../lib/config");
const { syncAdminUserIndex } = require("../lib/adminUserIndex");
const { revenueSummaryAmounts } = require("../lib/revenueLedger");
const {
	enqueueRevenueEvent,
	processRevenueEvent,
} = require("../lib/revenueOutbox");
const {
	recordSubscriptionIssue,
	resolveSubscriptionIssues,
} = require("../lib/subscriptionIssues");
const {
	reconcileUserEntitlement,
} = require("../lib/subscriptionReconciler");

test(
	"admin sync and reconciliation survive quarantined history",
	{ timeout: 30_000 },
	async () => {
		assert.ok(process.env.FIRESTORE_EMULATOR_HOST);
		assert.ok(process.env.FIREBASE_AUTH_EMULATOR_HOST);
		const suffix = `${Date.now()}-${process.pid}`;
		const uid = `billing-reliability-${suffix}`;
		const purchaseToken = `play-token-${suffix}`;
		const userRef = db.collection("users").doc(uid);
		const providerRef = db.collection("subscriptions").doc(purchaseToken);
		const adminRef = db.collection("adminUsers").doc(uid);

		await auth.createUser({
			uid,
			email: `${uid}@example.test`,
			emailVerified: true,
			displayName: "Billing Test",
		});
		try {
			await Promise.all([
				userRef.set({ email: `${uid}@example.test`, displayName: "Billing Test" }),
				providerRef.set({
					plan: "pro",
					source: "play_store",
					environment: "production",
					userId: uid,
					purchaseToken,
					billingPeriod: "monthly",
					subscriptionState: "SUBSCRIPTION_STATE_ACTIVE",
					entitlementState: "active",
					renewalState: "renewing",
					willAutoRenew: true,
					expiresAt: Timestamp.fromMillis(Date.now() + 30 * 86400000),
				}),
			]);
			const issueId = await recordSubscriptionIssue({
				type: "razorpay_verification_failed",
				source: "razorpay",
				providerKey: `historical-${suffix}`,
				userId: uid,
				status: "quarantined",
				details: { providerStatus: 400 },
			});

			const reconciled = await reconcileUserEntitlement(uid);
			assert.equal(reconciled.plan, "pro");
			assert.equal(reconciled.primarySource, "play_store");
			assert.equal((await db.collection("adminSubscriptionIssues").doc(issueId).get()).get("status"), "quarantined");

			await syncAdminUserIndex(uid);
			const indexed = (await adminRef.get()).data();
			assert.equal(indexed.subscriptionClass, "paid");
			assert.equal(indexed.subscriptionSource, "play_store");
			assert.ok(indexed.authCreatedAt instanceof Timestamp);
			const claims = (await auth.getUser(uid)).customClaims;
			assert.equal(claims.plan, "pro");
		} finally {
			await Promise.all([
				auth.deleteUser(uid).catch(() => undefined),
				db.recursiveDelete(userRef).catch(() => undefined),
				providerRef.delete().catch(() => undefined),
				adminRef.delete().catch(() => undefined),
				db.collection("adminSubscriptionIssues").where("userId", "==", uid).get().then(async (snapshot) => {
					const batch = db.batch();
					for (const document of snapshot.docs) batch.delete(document.ref);
					await batch.commit();
				}).catch(() => undefined),
			]);
		}
	},
);

test(
	"issue transitions and RTDN/report revenue are idempotent",
	{ timeout: 30_000 },
	async () => {
		assert.ok(process.env.FIRESTORE_EMULATOR_HOST);
		const suffix = `${Date.now()}-${process.pid}`;
		const providerKey = `gone-token-${suffix}`;
		const issueId = await recordSubscriptionIssue({
			type: "play_verification_failed",
			source: "play_store",
			providerKey,
			details: { errorCode: "410" },
		});
		await recordSubscriptionIssue({
			type: "play_verification_failed",
			source: "play_store",
			providerKey,
			status: "quarantined",
			details: { errorCode: "410" },
		});
		let issue = await db.collection("adminSubscriptionIssues").doc(issueId).get();
		assert.equal(issue.get("status"), "quarantined");
		assert.equal(issue.get("actionable"), false);
		await resolveSubscriptionIssues(providerKey, "play_store");
		issue = await db.collection("adminSubscriptionIssues").doc(issueId).get();
		assert.equal(issue.get("status"), "resolved");

		const orderId = `GPA.${suffix}`;
		const input = {
			provider: "play_store",
			providerTransactionId: `${orderId}:charge`,
			userId: null,
			amountMicros: 2_990_000,
			currency: "EUR",
			kind: "charge",
			environment: "production",
			occurredAt: new Date("2026-08-15T10:00:00.000Z"),
			metadata: { source: "orders_api" },
		};
		const summaryRef = db.collection("adminRevenueSummary").doc("lifetime");
		const before = revenueSummaryAmounts((await summaryRef.get()).data())
			.grossCurrencies.EUR ?? 0;
		const rtdnEventId = await enqueueRevenueEvent(input);
		const reportEventId = await enqueueRevenueEvent({
			...input,
			metadata: { source: "sales_report" },
		});
		assert.equal(reportEventId, rtdnEventId);
		assert.equal(await processRevenueEvent(rtdnEventId), "processed");
		assert.equal(await processRevenueEvent(reportEventId), "skipped");

		const transactions = await db
			.collection("adminRevenueTransactions")
			.where("providerTransactionId", "==", `${orderId}:charge`)
			.get();
		assert.equal(transactions.size, 1);
		const after = revenueSummaryAmounts((await summaryRef.get()).data())
			.grossCurrencies.EUR ?? 0;
		assert.equal(after - before, 2_990_000);

		await Promise.all([
			db.collection("adminSubscriptionIssues").doc(issueId).delete(),
			db.collection("adminRevenueEvents").doc(rtdnEventId).delete(),
			...transactions.docs.map((document) => document.ref.delete()),
		]);
	},
);

test(
	"deleted users resolve obsolete claim failures without throwing",
	{ timeout: 30_000 },
	async () => {
		const suffix = `${Date.now()}-${process.pid}`;
		const uid = `deleted-billing-user-${suffix}`;
		const providerRef = db.collection("subscriptions").doc(`deleted-${suffix}`);
		await providerRef.set({
			plan: "pro",
			source: "play_store",
			environment: "production",
			userId: uid,
			subscriptionState: "SUBSCRIPTION_STATE_EXPIRED",
			entitlementState: "ended",
			renewalState: "notRenewing",
			willAutoRenew: false,
			expiresAt: Timestamp.fromMillis(Date.now() - 1000),
		});
		try {
			const result = await reconcileUserEntitlement(uid);
			assert.equal(result.plan, "free");
			const issues = await db
				.collection("adminSubscriptionIssues")
				.where("userId", "==", uid)
				.where("type", "==", "claims_sync_failed")
				.get();
			assert.equal(issues.size, 1);
			assert.equal(issues.docs[0].get("status"), "resolved");
			assert.equal(issues.docs[0].get("resolution"), "auth_user_deleted");
		} finally {
			await providerRef.delete().catch(() => undefined);
			await db.recursiveDelete(db.collection("users").doc(uid)).catch(() => undefined);
			const issues = await db.collection("adminSubscriptionIssues").where("userId", "==", uid).get();
			const batch = db.batch();
			for (const document of issues.docs) batch.delete(document.ref);
			await batch.commit();
		}
	},
);

test(
	"billing activity indexes support filtered cursor pagination",
	{ timeout: 30_000 },
	async () => {
		const suffix = `${Date.now()}-${process.pid}`;
		const collection = db.collection("adminBillingActivities");
		const documents = [
			collection.doc(`activity-a-${suffix}`),
			collection.doc(`activity-b-${suffix}`),
			collection.doc(`activity-c-${suffix}`),
		];
		await Promise.all(
			documents.map((reference, index) =>
				reference.set({
					provider: index === 2 ? "app_store" : "play_store",
					eventType: index === 0 ? "purchase" : "renewal",
					occurredAt: Timestamp.fromMillis(1000 + index),
				}),
			),
		);
		try {
			const first = await collection
				.where("provider", "==", "play_store")
				.orderBy("occurredAt", "desc")
				.orderBy(FieldPath.documentId(), "desc")
				.limit(1)
				.get();
			assert.equal(first.size, 1);
			assert.equal(first.docs[0].get("eventType"), "renewal");
			const second = await collection
				.where("provider", "==", "play_store")
				.orderBy("occurredAt", "desc")
				.orderBy(FieldPath.documentId(), "desc")
				.startAfter(
					first.docs[0].get("occurredAt"),
					first.docs[0].id,
				)
				.limit(1)
				.get();
			assert.equal(second.size, 1);
			assert.equal(second.docs[0].get("eventType"), "purchase");
		} finally {
			await Promise.all(documents.map((reference) => reference.delete()));
		}
	},
);
