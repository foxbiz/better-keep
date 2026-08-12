/**
 * Grants or revokes the Better Keep admin claim. Dry-run is the default.
 *
 * Grant the dedicated account:
 *   ADMIN_ACCOUNT_UID=<uid> npm run admin:bootstrap -- \
 *     --action=grant --email=admin@betterkeep.app \
 *     --execute --project=better-keep-notes --database=better-keep
 *
 * Revoke an old account:
 *   npm run admin:bootstrap -- \
 *     --action=revoke --email=former@example.com \
 *     --execute --project=better-keep-notes --database=better-keep
 */
import * as readline from "node:readline/promises";
import { mergeAdminClaim, removeAdminClaim } from "../src/adminAccess";
import { ADMIN_ACCESS_CLAIM, configuredAdminUid } from "../src/adminConfig";
import { app, auth, databaseId } from "../src/config";

const EXPECTED_PROJECT = "better-keep-notes";
const EXPECTED_DATABASE = "better-keep";

function argument(name: string): string | null {
	const prefix = `--${name}=`;
	return process.argv.find((value) => value.startsWith(prefix))?.slice(prefix.length) ?? null;
}

async function confirmTarget(action: string, uid: string): Promise<void> {
	if (!process.stdin.isTTY) throw new Error("Execution requires an interactive terminal");
	const prompt = readline.createInterface({ input: process.stdin, output: process.stdout });
	try {
		const expected = `${action} ${uid} ${EXPECTED_PROJECT}/${EXPECTED_DATABASE}`;
		const answer = await prompt.question(`Type ${expected} to continue: `);
		if (answer.trim() !== expected) throw new Error("Target confirmation did not match");
	} finally {
		prompt.close();
	}
}

async function main(): Promise<void> {
	const execute = process.argv.includes("--execute");
	const action = argument("action") ?? "grant";
	if (action !== "grant" && action !== "revoke" && action !== "verify") {
		throw new Error("--action must be grant, revoke, or verify");
	}
	const email = argument("email");
	const uid = argument("uid");
	if ((email ? 1 : 0) + (uid ? 1 : 0) !== 1) {
		throw new Error("Provide exactly one of --email or --uid");
	}
	const user = email ? await auth.getUserByEmail(email) : await auth.getUser(uid as string);
	const resolvedProject = app.options.projectId ?? process.env.GOOGLE_CLOUD_PROJECT;
	console.log(`Mode: ${execute ? "EXECUTE" : "DRY RUN"}`);
	console.log(`Action: ${action}`);
	console.log(`Target UID: ${user.uid}`);
	console.log(`Target email: ${user.email ?? "(none)"}`);
	console.log(`Resolved project/database: ${resolvedProject}/${databaseId}`);

	if (action === "grant" || action === "verify") {
		if (!user.emailVerified) throw new Error("The admin Firebase email must be verified");
		if (!user.providerData.some((provider) => provider.providerId === "password")) {
			throw new Error("The admin account must have the password provider linked");
		}
		const expectedUid = configuredAdminUid();
		if (!expectedUid || expectedUid !== user.uid) {
			throw new Error("ADMIN_ACCOUNT_UID must match the account receiving the claim");
		}
	}

	console.log(`Existing claim: ${user.customClaims?.[ADMIN_ACCESS_CLAIM] === true}`);
	const enrolledFactors = user.multiFactor?.enrolledFactors ?? [];
	console.log(`Enrolled MFA factors: ${enrolledFactors.map((factor) => factor.factorId).join(", ") || "none"}`);
	if (action === "verify") {
		if (user.customClaims?.[ADMIN_ACCESS_CLAIM] !== true) {
			throw new Error("The configured account does not have the admin claim");
		}
		if (!enrolledFactors.some((factor) => factor.factorId === "totp")) {
			throw new Error("The configured account has not enrolled a TOTP factor");
		}
		console.log("Administrator identity is ready: verified password, claim, UID, and TOTP match.");
		return;
	}
	if (!execute) {
		console.log("Dry run complete. No authentication state changed.");
		return;
	}
	if (
		argument("project") !== EXPECTED_PROJECT ||
		argument("database") !== EXPECTED_DATABASE ||
		resolvedProject !== EXPECTED_PROJECT ||
		databaseId !== EXPECTED_DATABASE
	) {
		throw new Error("Resolved and explicit Firebase targets must match production");
	}
	await confirmTarget(action, user.uid);
	const claims = action === "grant"
		? mergeAdminClaim(user.customClaims)
		: removeAdminClaim(user.customClaims);
	await auth.setCustomUserClaims(user.uid, claims);
	await auth.revokeRefreshTokens(user.uid);
	console.log(`Admin access ${action === "grant" ? "granted" : "revoked"}; tokens revoked.`);
}

main().catch((error: unknown) => {
	console.error(error instanceof Error ? error.message : error);
	process.exitCode = 1;
});
