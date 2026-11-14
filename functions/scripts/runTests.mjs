#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const functionsDirectory = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"..",
);

// Explicit suites keep emulator/integration tests out of the ordinary unit run.
const suites = {
	unit: [
		"test/reminderStateResolver.test.js",
		"test/reviewAccess.test.js",
		"test/reviewCallableContract.test.js",
		"test/operationsConfig.test.js",
		"test/deploymentEnv.test.mjs",
		"test/publicStats.test.js",
		"test/reviewResetPolicy.test.js",
		"test/reviewAccountReset.test.js",
		"test/passwordResetPolicy.test.js",
		"test/customClaims.test.js",
		"test/accountLinkProviders.test.js",
		"test/oauthSession.test.js",
		"test/storageConnectionSecurity.test.js",
		"test/encryptedStorageConnectionService.test.js",
		"test/resetStorageConnections.test.js",
		"test/storageOAuth.test.js",
		"test/oauthTokenExchange.test.js",
		"test/storageTokenExchangeBackend.test.js",
		"test/storageTokenBinding.test.js",
		"test/storageTokenBindingFlow.test.js",
		"test/oauthResponse.test.js",
		"test/desktopAppleAuth.test.js",
		"test/accountLinkSession.test.js",
		"test/nativeAccountLinkPolicy.test.js",
		"test/syncCommitStamp.test.js",
		"test/legacySyncStamp.test.js",
		"test/emailDelivery.test.js",
		"test/adminAccess.test.js",
		"test/adminAudit.test.js",
		"test/adminContract.test.js",
		"test/adminIdentityToolkitUsers.test.js",
		"test/adminSearch.test.js",
		"test/adminSubscription.test.js",
		"test/adminMetrics.test.js",
		"test/appStoreSubscription.test.js",
		"test/billingActivity.test.js",
		"test/billingReconciliation.test.js",
		"test/boundedConcurrency.test.js",
		"test/checkExistingSubscription.test.js",
		"test/processScheduledDeletions.test.js",
		"test/reconcileProviderSubscriptions.test.js",
		"test/revenueLedger.test.js",
		"test/revenueOutbox.test.js",
		"test/revenueReconciler.test.js",
		"test/googlePlayRevenue.test.js",
		"test/googlePlayReconciliation.test.js",
		"test/googlePlaySubscription.test.js",
		"test/playStoreWebhook.test.js",
		"test/razorpaySubscription.test.js",
		"test/razorpayPlanCatalog.test.js",
		"test/subscriptionEntitlement.test.js",
		"test/subscriptionReconciler.test.js",
	],
	deletion: [
		"functions/test/accountDeletionLifecycle.emulator.test.js",
		"functions/test/accountDeletion.e2e.test.js",
		"test/firestore_rules/account_deletion_rules_test.mjs",
	],
	emulator: [
		"test/reminderStateResolver.emulator.test.js",
		"test/reviewAccountCleanup.emulator.test.js",
		"test/accountLinkSession.emulator.test.js",
		"test/adminBillingReliability.emulator.test.js",
		"test/nativeAccountLinkPolicy.emulator.test.js",
		"test/oauthCompletion.emulator.test.js",
		"test/storageOAuth.emulator.test.js",
		"test/storageTokenBinding.emulator.test.js",
		"test/syncCommitStamp.emulator.test.js",
		"test/googlePlayReplacement.emulator.test.js",
	],
};

const [suiteName = "unit", ...testArguments] = process.argv.slice(2);
const files = suites[suiteName];
if (!files) {
	console.error(
		`Unknown test suite: ${suiteName}. Choose unit, emulator, or deletion.`,
	);
	process.exit(1);
}

function run(arguments_, cwd = functionsDirectory) {
	const result = spawnSync(process.execPath, arguments_, {
		cwd,
		stdio: "inherit",
	});
	if (result.error) throw result.error;
	if (result.status !== 0) process.exit(result.status ?? 1);
}

const compiler = path.join(
	functionsDirectory,
	"node_modules/typescript/bin/tsc",
);
// Every entry point must test current sources, including direct deletion runs.
run([compiler]);
if (suiteName === "unit" || suiteName === "emulator") {
	run([compiler, "--project", "tsconfig.scripts.json"]);
}
run(
	[
		"--test",
		...(suiteName === "deletion" ? ["--test-concurrency=1"] : []),
		...testArguments,
		...files,
	],
	suiteName === "deletion"
		? path.dirname(functionsDirectory)
		: functionsDirectory,
);
