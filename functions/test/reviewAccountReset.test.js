const assert = require("node:assert/strict");
const test = require("node:test");
const {
	executeReviewAccountReset,
} = require("../lib/reviewAccountReset");

test("review reset failure leaves the identity disabled and retry converges", async () => {
	const state = {
		disabled: false,
		revokeCount: 0,
		cleanupCount: 0,
		restoreAttempts: 0,
	};
	const identity = {
		uid: "review-user",
		providerIds: ["password", "google.com"],
	};

	const operations = {
		existingIdentity: identity,
		revokeSessions: async () => {
			state.revokeCount += 1;
		},
		disableIdentity: async () => {
			state.disabled = true;
			return identity;
		},
		createDisabledIdentity: async () => {
			throw new Error("existing identity must be retained");
		},
		cleanup: async () => {
			state.cleanupCount += 1;
			return { deleted: state.cleanupCount };
		},
		resetAuthentication: async () => {},
		restoreEntitlement: async () => {
			state.restoreAttempts += 1;
			if (state.restoreAttempts === 1) {
				throw new Error("transient entitlement failure");
			}
		},
		restoreClaims: async () => {},
		enableIdentity: async () => {
			state.disabled = false;
		},
	};

	await assert.rejects(executeReviewAccountReset(operations));
	assert.equal(state.disabled, true);
	assert.equal(state.cleanupCount, 1);

	const result = await executeReviewAccountReset(operations);
	assert.equal(result.uid, identity.uid);
	assert.equal(state.disabled, false);
	assert.equal(state.revokeCount, 2);
	assert.equal(state.cleanupCount, 2);
	assert.equal(state.restoreAttempts, 2);
});

test("review reset creates an absent identity disabled before cleanup", async () => {
	const order = [];
	const identity = { uid: "new-review-user", providerIds: ["password"] };
	const result = await executeReviewAccountReset({
		existingIdentity: null,
		revokeSessions: async () => {
			throw new Error("absent identity has no sessions");
		},
		disableIdentity: async () => {
			throw new Error("absent identity cannot be disabled");
		},
		createDisabledIdentity: async () => {
			order.push("create-disabled");
			return identity;
		},
		cleanup: async () => {
			order.push("cleanup");
			return "clean";
		},
		resetAuthentication: async () => order.push("reset-auth"),
		restoreEntitlement: async () => order.push("restore-entitlement"),
		restoreClaims: async () => order.push("restore-claims"),
		enableIdentity: async () => order.push("enable"),
	});

	assert.equal(result.uid, identity.uid);
	assert.deepEqual(order, [
		"create-disabled",
		"cleanup",
		"reset-auth",
		"restore-entitlement",
		"restore-claims",
		"enable",
	]);
});

test("session revocation failure still leaves an existing identity disabled", async () => {
	let disabled = false;
	await assert.rejects(
		executeReviewAccountReset({
			existingIdentity: { uid: "review-user", providerIds: ["password"] },
			disableIdentity: async (uid) => {
				disabled = true;
				return { uid, providerIds: ["password"] };
			},
			revokeSessions: async () => {
				throw new Error("revocation unavailable");
			},
			createDisabledIdentity: async () => {
				throw new Error("must not create");
			},
			cleanup: async () => {
				throw new Error("must not clean before revocation");
			},
			resetAuthentication: async () => {},
			restoreEntitlement: async () => {},
			restoreClaims: async () => {},
			enableIdentity: async () => {
				disabled = false;
			},
		}),
		/revocation unavailable/,
	);
	assert.equal(disabled, true);
});
