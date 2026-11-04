#!/usr/bin/env node
// Account-scoped recovery only after the original invocation has stopped.
import { parseArgs } from "node:util";
import { initializeApp, deleteApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { isVerifiedDeletion } from "../lib/accountDeletionLifecycle.js";
import { revokeDeletionSessions } from "../lib/deletionSessionRevocation.js";

async function main() {
	const { values } = parseArgs({
		options: {
			project: { type: "string" },
			database: { type: "string" },
			uid: { type: "string" },
			"request-id": { type: "string" },
			attempt: { type: "string" },
			execute: { type: "boolean", default: false },
			"confirm-invocation-stopped": { type: "boolean", default: false },
		},
	});
	for (const key of ["project", "database", "uid", "request-id", "attempt"]) {
		if (!values[key] || /[\s/]/.test(values[key]))
			throw new Error(
				`Required explicit --${key}=value (no whitespace or slash)`,
			);
	}
	const uuid =
		/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
	if (!uuid.test(values["request-id"]) || !uuid.test(values.attempt))
		throw new Error("Request and attempt must be UUIDs");
	if (values.execute && !values["confirm-invocation-stopped"])
		throw new Error(
			"Execution requires --confirm-invocation-stopped; timeout alone is insufficient",
		);
	const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST;
	const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST;
	if (firestoreHost || authHost) {
		const local = /^(127\.0\.0\.1|localhost):\d+$/;
		if (
			!local.test(firestoreHost || "") ||
			!local.test(authHost || "") ||
			!values.project.startsWith("demo-")
		)
			throw new Error(
				"Emulator recovery requires both loopback emulators and an explicit demo project",
			);
	} else if (values.project.startsWith("demo-")) {
		throw new Error("Demo recovery requires emulators");
	}
	const app = initializeApp({ projectId: values.project });
	try {
		const db = getFirestore(app, values.database);
		const userRef = db.collection("users").doc(values.uid);
		const auditRef = db
			.collection("accountDeletionRequests")
			.doc(values["request-id"]);
		await db.runTransaction(async (tx) => {
			const user = await tx.get(userRef);
			const audit = await tx.get(auditRef);
			const schedule = user.data()?.scheduledDeletion;
			const proof = audit.data();
			if (
				schedule?.requestId !== values["request-id"] ||
				!isVerifiedDeletion(schedule, proof, values.uid) ||
				proof?.state !== "revoking" ||
				proof.revocationAttempt !== values.attempt ||
				!(proof.revocationDispatchedAt instanceof Timestamp) ||
				!(proof.revocationLeaseUntil instanceof Timestamp)
			)
				throw new Error(
					"Request/owner/state/attempt does not match a dispatched revocation",
				);
			const now = Timestamp.now();
			if (proof.revocationLeaseUntil.toMillis() > now.toMillis())
				throw new Error(
					"Attempt lease has not expired; do not recover an active invocation",
				);
			if (values.execute)
				tx.update(auditRef, {
					revocationDispatchedAt: FieldValue.delete(),
					revocationLeaseUntil: now,
					revocationRecoveredAt: now,
					revocationRecoveredAttempt: values.attempt,
				});
		});
		if (!values.execute) {
			console.log(
				"Dry run: matching stranded request. No changes made. Independently confirm the old invocation stopped before execution.",
			);
			return;
		}
		await revokeDeletionSessions(
			db,
			values.uid,
			values["request-id"],
			async (uid) => {
				try {
					await getAuth(app).revokeRefreshTokens(uid);
				} catch (error) {
					if (error?.code !== "auth/user-not-found") throw error;
				}
			},
		);
		console.log(
			"Recovery finished. Revocation completed or the request was already completed/cancelled.",
		);
	} finally {
		await deleteApp(app);
	}
}
main().catch((error) => {
	console.error(error.message);
	process.exitCode = 1;
});
