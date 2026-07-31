const assert = require("node:assert/strict");
const test = require("node:test");
const {
	resolveReviewResetTarget,
	REVIEW_RESET_DATABASE_ID,
	REVIEW_RESET_PROJECT_ID,
	REVIEW_RESET_STORAGE_BUCKET,
} = require("../lib/reviewResetPolicy");

const productionEnvironment = {
	GOOGLE_APPLICATION_CREDENTIALS: "/credentials/review-reset.json",
};
const loadExpectedCredential = () => REVIEW_RESET_PROJECT_ID;

test("review reset defaults to a production dry run with verified ADC", () => {
	assert.deepEqual(
		resolveReviewResetTarget({
			execute: false,
			arguments: [],
			environment: productionEnvironment,
			loadCredentialProjectId: loadExpectedCredential,
		}),
		{
			isEmulator: false,
			projectId: REVIEW_RESET_PROJECT_ID,
			databaseId: REVIEW_RESET_DATABASE_ID,
			storageBucket: REVIEW_RESET_STORAGE_BUCKET,
		},
	);
});

test("review reset rejects partial emulator configuration", () => {
	assert.throws(
		() =>
			resolveReviewResetTarget({
				execute: false,
				arguments: [],
				environment: {
					FIREBASE_AUTH_EMULATOR_HOST: "127.0.0.1:9099",
				},
				loadCredentialProjectId: loadExpectedCredential,
			}),
		/emulator host variables must be set together/i,
	);
});

test("review reset uses only the default database with all emulators", () => {
	assert.deepEqual(
		resolveReviewResetTarget({
			execute: true,
			arguments: [],
			environment: {
				FIREBASE_AUTH_EMULATOR_HOST: "127.0.0.1:9099",
				FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080",
				FIREBASE_STORAGE_EMULATOR_HOST: "127.0.0.1:9199",
				FUNCTIONS_EMULATOR: "true",
			},
			loadCredentialProjectId: () => {
				throw new Error("ADC must not be read for emulator execution");
			},
		}),
		{
			isEmulator: true,
			projectId: REVIEW_RESET_PROJECT_ID,
			databaseId: "(default)",
			storageBucket: REVIEW_RESET_STORAGE_BUCKET,
		},
	);
});

test("production execution requires explicit exact targets", () => {
	const base = {
		execute: true,
		environment: productionEnvironment,
		loadCredentialProjectId: loadExpectedCredential,
	};
	assert.throws(
		() => resolveReviewResetTarget({ ...base, arguments: [] }),
		/execution requires/i,
	);
	assert.throws(
		() =>
			resolveReviewResetTarget({
				...base,
				arguments: [
					"--project=other-project",
					`--database=${REVIEW_RESET_DATABASE_ID}`,
				],
			}),
		/execution requires/i,
	);
	assert.equal(
		resolveReviewResetTarget({
			...base,
			arguments: [
				`--project=${REVIEW_RESET_PROJECT_ID}`,
				`--database=${REVIEW_RESET_DATABASE_ID}`,
			],
		}).databaseId,
		REVIEW_RESET_DATABASE_ID,
	);
});

test("production reset rejects missing or mismatched ADC", () => {
	assert.throws(
		() =>
			resolveReviewResetTarget({
				execute: false,
				arguments: [],
				environment: {},
				loadCredentialProjectId: loadExpectedCredential,
			}),
		/GOOGLE_APPLICATION_CREDENTIALS/,
	);
	assert.throws(
		() =>
			resolveReviewResetTarget({
				execute: false,
				arguments: [],
				environment: productionEnvironment,
				loadCredentialProjectId: () => "other-project",
			}),
		/project does not match/i,
	);
});
