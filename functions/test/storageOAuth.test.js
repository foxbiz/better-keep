const { test } = require("node:test");
const assert = require("node:assert/strict");
// No network or database queries: test only the retired callable handlers.
process.env.GCLOUD_PROJECT ||= "demo-storage-retired";
const backend = require("../lib/storageOAuthBackend");
const connections = require("../lib/storageConnectionBackend");
test("retired token and consent callables fail closed without provider secrets", async () => {
	for (const handler of [
		backend.prepareStorageOAuth,
		backend.completeStorageOAuth,
		backend.cancelStorageOAuth,
		connections.getStorageAccess,
		connections.connectNextcloudStorage,
	]) {
		await assert.rejects(
			async () =>
				handler.run({ auth: { uid: "test-user", token: {} }, data: {} }),
			(error) => error.code === "failed-precondition",
		);
	}
});
test("retired browser callbacks return 410 without reflecting request data", async () => {
	for (const handler of [
		backend.storageOAuthStart,
		backend.storageOAuthCallback,
	]) {
		let status, body;
		const response = {
			set() {
				return this;
			},
			status(value) {
				status = value;
				return this;
			},
			type() {
				return this;
			},
			send(value) {
				body = value;
				return this;
			},
		};
		await handler({ query: { code: "private-provider-code" } }, response);
		assert.equal(status, 410);
		assert.equal(body.includes("private-provider-code"), false);
	}
});
