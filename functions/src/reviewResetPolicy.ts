export const REVIEW_RESET_PROJECT_ID = "better-keep-notes";
export const REVIEW_RESET_DATABASE_ID = "better-keep";
export const REVIEW_RESET_STORAGE_BUCKET =
	"better-keep-notes.firebasestorage.app";

export const REVIEW_RESET_EMULATOR_HOST_VARIABLES = [
	"FIREBASE_AUTH_EMULATOR_HOST",
	"FIRESTORE_EMULATOR_HOST",
	"FIREBASE_STORAGE_EMULATOR_HOST",
] as const;

export interface ReviewResetTarget {
	isEmulator: boolean;
	projectId: typeof REVIEW_RESET_PROJECT_ID;
	databaseId: string;
	storageBucket: typeof REVIEW_RESET_STORAGE_BUCKET;
}

interface ReviewResetPolicyOptions {
	execute: boolean;
	arguments: readonly string[];
	environment: Readonly<Record<string, string | undefined>>;
	loadCredentialProjectId(path: string): string | undefined;
}

function argumentValue(
	arguments_: readonly string[],
	name: string,
): string | undefined {
	const prefix = `--${name}=`;
	return arguments_
		.find((value) => value.startsWith(prefix))
		?.slice(prefix.length);
}

export function resolveReviewResetTarget({
	execute,
	arguments: arguments_,
	environment,
	loadCredentialProjectId,
}: ReviewResetPolicyOptions): ReviewResetTarget {
	const configuredHosts = REVIEW_RESET_EMULATOR_HOST_VARIABLES.filter(
		(name) => !!environment[name],
	);
	if (
		configuredHosts.length !== 0 &&
		configuredHosts.length !== REVIEW_RESET_EMULATOR_HOST_VARIABLES.length
	) {
		throw new Error(
			"All Auth, Firestore and Storage emulator host variables must be set together",
		);
	}

	const isEmulator =
		configuredHosts.length === REVIEW_RESET_EMULATOR_HOST_VARIABLES.length;
	if (isEmulator) {
		if (environment.FUNCTIONS_EMULATOR !== "true") {
			throw new Error("FUNCTIONS_EMULATOR=true is required for emulator reset");
		}
		return {
			isEmulator: true,
			projectId: REVIEW_RESET_PROJECT_ID,
			databaseId: "(default)",
			storageBucket: REVIEW_RESET_STORAGE_BUCKET,
		};
	}

	const requestedProject = argumentValue(arguments_, "project");
	const requestedDatabase = argumentValue(arguments_, "database");
	if (
		execute &&
		(requestedProject !== REVIEW_RESET_PROJECT_ID ||
			requestedDatabase !== REVIEW_RESET_DATABASE_ID)
	) {
		throw new Error(
			`Execution requires --project=${REVIEW_RESET_PROJECT_ID} --database=${REVIEW_RESET_DATABASE_ID}`,
		);
	}
	if (
		requestedProject !== undefined &&
		requestedProject !== REVIEW_RESET_PROJECT_ID
	) {
		throw new Error(`Unexpected project target: ${requestedProject}`);
	}
	if (
		requestedDatabase !== undefined &&
		requestedDatabase !== REVIEW_RESET_DATABASE_ID
	) {
		throw new Error(`Unexpected database target: ${requestedDatabase}`);
	}

	const credentialPath = environment.GOOGLE_APPLICATION_CREDENTIALS;
	if (!credentialPath) {
		throw new Error(
			"GOOGLE_APPLICATION_CREDENTIALS must point to the approved production service-account JSON",
		);
	}
	if (loadCredentialProjectId(credentialPath) !== REVIEW_RESET_PROJECT_ID) {
		throw new Error("ADC service-account project does not match the target");
	}

	return {
		isEmulator: false,
		projectId: REVIEW_RESET_PROJECT_ID,
		databaseId: REVIEW_RESET_DATABASE_ID,
		storageBucket: REVIEW_RESET_STORAGE_BUCKET,
	};
}
