import { after, before, beforeEach, test } from "node:test";
import { readFile } from "node:fs/promises";
import {
  assertFails,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc } from "firebase/firestore";

const projectId = "demo-better-keep-admin-firestore-rules";
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: { rules: await readFile("firestore.rules", "utf8") },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

after(async () => {
  await testEnv.cleanup();
});

test("even a claimed administrator cannot access backend-only data directly", async () => {
  const db = testEnv.authenticatedContext("admin-uid", {
    email: "admin@betterkeep.app",
    email_verified: true,
    appAdmin: true,
  }).firestore();

  for (const path of [
    "adminUsers/user-1",
    "adminMetrics/current",
    "adminRevenueTransactions/payment-1",
    "adminRevenueSummary/lifetime",
    "adminAuditLogs/audit-1",
    "adminRevenueEvents/event-1",
    "adminSubscriptionIssues/issue-1",
    "adminBillingActivities/activity-1",
    "playStoreWebhookEvents/event-1",
    "razorpayWebhookEvents/event-1",
  ]) {
    await assertFails(getDoc(doc(db, path)));
    await assertFails(setDoc(doc(db, path), { forged: true }));
  }
});
