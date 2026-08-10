import assert from "node:assert/strict";
import test from "node:test";
import {
	billingReconciliationNodeArguments,
	createAdcSecretAccessor,
	runBillingReconciliation,
	validateBillingReconciliationArguments,
} from "../../tool/run_billing_reconciliation.mjs";

test("reads and decodes only the requested production Secret Manager version", async () => {
	let requestedName = null;
	const accessSecret = createAdcSecretAccessor({
		googleApis: {
			google: {
				auth: { GoogleAuth: class {} },
				secretmanager: () => ({
					projects: {
						secrets: {
							versions: {
								access: async ({ name }) => {
									requestedName = name;
									return {
										data: {
											payload: {
												data: Buffer.from("secret-value").toString("base64"),
											},
										},
									};
								},
							},
						},
					},
				}),
			},
		},
	});
	assert.equal(await accessSecret("GOOGLE_PLAY_CREDENTIALS"), "secret-value");
	assert.equal(
		requestedName,
		"projects/better-keep-notes/secrets/GOOGLE_PLAY_CREDENTIALS/versions/latest",
	);
});

test("pins billing reconciliation to the production project and database", () => {
	assert.deepEqual(
		validateBillingReconciliationArguments([
			"--project=better-keep-notes",
			"--database=better-keep",
		]),
		["--project=better-keep-notes", "--database=better-keep"],
	);
	assert.throws(
		() => validateBillingReconciliationArguments(["--project=other"]),
		/--project must be better-keep-notes/,
	);
	assert.throws(
		() => validateBillingReconciliationArguments(["--database=other"]),
		/--database must be better-keep/,
	);
	assert.deepEqual(
		validateBillingReconciliationArguments(["--provider=play"]),
		["--provider=play"],
	);
	assert.throws(
		() => validateBillingReconciliationArguments(["--provider=unknown"]),
		/--provider must be all, play, or razorpay/,
	);
});

test("loads functions env before the TypeScript reconciliation entrypoint", () => {
	assert.deepEqual(billingReconciliationNodeArguments(["--execute"]), [
		"--env-file-if-exists=.env",
		"--import",
		"tsx",
		"scripts/reconcileBillingData.ts",
		"--execute",
	]);
});

test("reads missing provider credentials without exposing them in arguments", async () => {
	const requestedSecrets = [];
	let child = null;
	const exitCode = await runBillingReconciliation([], {
		processEnv: { PATH: "/bin" },
		processExecPath: "/node",
		root: "/repo",
		readSecret: async (name) => {
			requestedSecrets.push(name);
			return `secret-${name}`;
		},
		runProcess: async (options) => {
			child = options;
			return 0;
		},
	});
	assert.equal(exitCode, 0);
	assert.deepEqual(requestedSecrets, [
		"GOOGLE_PLAY_CREDENTIALS",
		"RAZORPAY_KEY_ID",
		"RAZORPAY_KEY_SECRET",
	]);
	assert.equal(child.cwd, "/repo/functions");
	assert.equal(child.env.GOOGLE_CLOUD_PROJECT, "better-keep-notes");
	assert.equal(child.env.GOOGLE_CLOUD_QUOTA_PROJECT, "better-keep-notes");
	assert.equal(
		child.env.GOOGLE_PLAY_CREDENTIALS,
		"secret-GOOGLE_PLAY_CREDENTIALS",
	);
	assert.doesNotMatch(
		JSON.stringify(child.args),
		/secret-GOOGLE_PLAY_CREDENTIALS/,
	);
});

test("Play-only reconciliation reads no unrelated billing credentials", async () => {
	const requestedSecrets = [];
	await runBillingReconciliation(["--provider=play"], {
		processEnv: { PATH: "/bin" },
		processExecPath: "/node",
		root: "/repo",
		readSecret: async (name) => {
			requestedSecrets.push(name);
			return `secret-${name}`;
		},
		runProcess: async () => 0,
	});
	assert.deepEqual(requestedSecrets, ["GOOGLE_PLAY_CREDENTIALS"]);
});

test("never includes a failed secret response in the operator error", async () => {
	await assert.rejects(
		() =>
			runBillingReconciliation([], {
				processEnv: {},
				processExecPath: "/node",
				root: "/repo",
				readSecret: async () => {
					throw new Error("must-not-leak");
				},
			}),
		(error) => {
			assert.match(error.message, /GOOGLE_PLAY_CREDENTIALS/);
			assert.doesNotMatch(error.message, /must-not-leak/);
			return true;
		},
	);
});
