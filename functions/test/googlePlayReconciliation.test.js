const assert = require("node:assert/strict");
const test = require("node:test");
const { Timestamp } = require("firebase-admin/firestore");
const {
	buildGooglePlayReconciliationRow,
	candidateGooglePlayUserId,
	formatGooglePlayReconciliationReport,
	markGooglePlayOverlaps,
} = require("../lib/googlePlayReconciliation");

const future = Timestamp.fromDate(new Date("2099-09-08T00:00:00.000Z"));
const later = Timestamp.fromDate(new Date("2099-10-08T00:00:00.000Z"));
const past = Timestamp.fromDate(new Date("2020-01-01T00:00:00.000Z"));

function subscription({
	environment = "production",
	expiresAt = future,
	state = "SUBSCRIPTION_STATE_ACTIVE",
	willAutoRenew = true,
} = {}) {
	return {
		plan: "pro",
		source: "play_store",
		environment,
		expiresAt,
		subscriptionState: state,
		willAutoRenew,
	};
}

test("reports exact Play links without exposing raw purchase tokens", () => {
	const purchaseToken = "raw-provider-purchase-token";
	const row = buildGooglePlayReconciliationRow({
		externalAccountId: "firebase-uid",
		firebaseStatus: subscription(),
		linkedUserId: "firebase-uid",
		normalizedSubscription: subscription(),
		providerKey: purchaseToken,
		storedUserId: "firebase-uid",
	});
	assert.equal(row.classification, "linked_renewing");
	assert.equal(row.accountMatch, "exact");
	assert.equal(row.accessAligned, true);
	const output = formatGooglePlayReconciliationReport([row]);
	assert.doesNotMatch(output, new RegExp(purchaseToken));
	assert.match(output, /play:[a-f0-9]{12}/);
});

test("reports only sanitized provider error codes for failed verification", () => {
	const row = buildGooglePlayReconciliationRow({
		normalizedSubscription: subscription(),
		providerKey: "failed-token",
		verification: "failed",
		verificationErrorCode: 403,
	});
	const output = formatGooglePlayReconciliationReport([row]);
	assert.equal(row.classification, "verification_failed");
	assert.match(output, /"verificationErrorCode": 403/);
	assert.doesNotMatch(output, /failed-token/);
});

test("keeps authoritative Google state when Firebase identity lookup fails", () => {
	const row = buildGooglePlayReconciliationRow({
		externalAccountId: "firebase-uid",
		firebaseLookup: "failed",
		normalizedSubscription: subscription(),
		providerKey: "lookup-failed-token",
		storedUserId: "firebase-uid",
	});
	assert.equal(row.verification, "verified");
	assert.equal(row.googleEntitled, true);
	assert.equal(row.accountMatch, "unknown");
	assert.equal(row.classification, "unmatched");
});

test("keeps canceled subscriptions entitled through their future expiry", () => {
	const row = buildGooglePlayReconciliationRow({
		externalAccountId: "firebase-uid",
		firebaseStatus: subscription(),
		linkedUserId: "firebase-uid",
		normalizedSubscription: subscription({
			state: "SUBSCRIPTION_STATE_CANCELED",
			willAutoRenew: false,
		}),
		providerKey: "cancelled-token",
		storedUserId: "firebase-uid",
	});
	assert.equal(row.classification, "cancelled_access");
	assert.equal(row.googleEntitled, true);
	assert.equal(row.willAutoRenew, false);
});

test("does not treat held, expired, or test subscriptions as production access", () => {
	const held = buildGooglePlayReconciliationRow({
		linkedUserId: "firebase-uid",
		normalizedSubscription: subscription({
			state: "SUBSCRIPTION_STATE_ON_HOLD",
			willAutoRenew: false,
		}),
		providerKey: "held-token",
		storedUserId: "firebase-uid",
	});
	const expired = buildGooglePlayReconciliationRow({
		linkedUserId: "firebase-uid",
		normalizedSubscription: subscription({ expiresAt: past }),
		providerKey: "expired-token",
		storedUserId: "firebase-uid",
	});
	const licenseTest = buildGooglePlayReconciliationRow({
		linkedUserId: "firebase-uid",
		normalizedSubscription: subscription({ environment: "test" }),
		providerKey: "test-token",
		storedUserId: "firebase-uid",
	});
	assert.equal(held.classification, "suspended");
	assert.equal(held.googleEntitled, false);
	assert.equal(expired.classification, "expired_or_revoked");
	assert.equal(licenseTest.classification, "test");
	assert.equal(licenseTest.accessAligned, true);
});

test("requires exact account ownership and distinguishes recoverable records", () => {
	assert.equal(
		candidateGooglePlayUserId({
			externalAccountId: "new-user",
			storedUserId: "old-user",
		}),
		null,
	);
	const mismatch = buildGooglePlayReconciliationRow({
		externalAccountId: "new-user",
		normalizedSubscription: subscription(),
		providerKey: "mismatch-token",
		storedUserId: "old-user",
	});
	const recoverable = buildGooglePlayReconciliationRow({
		externalAccountId: "new-user",
		firebaseStatus: subscription(),
		linkedUserId: "new-user",
		normalizedSubscription: subscription(),
		providerKey: "recoverable-token",
	});
	assert.equal(mismatch.accountMatch, "mismatch");
	assert.equal(mismatch.classification, "unmatched");
	assert.equal(recoverable.classification, "recoverable");
});

test("counts overlapping provider records separately from the effective user", () => {
	const earlier = buildGooglePlayReconciliationRow({
		externalAccountId: "firebase-uid",
		firebaseStatus: subscription(),
		linkedUserId: "firebase-uid",
		normalizedSubscription: subscription(),
		providerKey: "earlier-token",
		storedUserId: "firebase-uid",
	});
	const latest = buildGooglePlayReconciliationRow({
		externalAccountId: "firebase-uid",
		firebaseStatus: subscription({ expiresAt: later }),
		linkedUserId: "firebase-uid",
		normalizedSubscription: subscription({ expiresAt: later }),
		providerKey: "latest-token",
		storedUserId: "firebase-uid",
	});
	const rows = markGooglePlayOverlaps([earlier, latest]);
	assert.equal(rows.length, 2);
	assert.equal(rows.filter((row) => row.classification === "overlap").length, 1);
	assert.equal(
		new Set(rows.map((row) => row.firebaseUserId)).size,
		1,
		"two provider subscriptions still represent one paid user",
	);
});
