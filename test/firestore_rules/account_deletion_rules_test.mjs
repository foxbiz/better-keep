import { after, before, test } from "node:test";
import { readFile } from "node:fs/promises";
import {
	assertFails,
	assertSucceeds,
	initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
	doc,
	getDoc,
	setDoc,
	updateDoc,
	deleteDoc,
	deleteField,
	Timestamp,
} from "firebase/firestore";
let env;
before(async () => {
	env = await initializeTestEnvironment({
		projectId: "demo-better-keep-deletion",
		firestore: { rules: await readFile("firestore.rules", "utf8") },
	});
});
after(() => env.cleanup());
test("deletion fields and audit proofs cannot be created, replaced, or deleted by clients", async () => {
	const db = env.authenticatedContext("rules-owner").firestore();
	const ref = doc(db, "users/rules-owner");
	const marker = { deleteAt: Timestamp.fromMillis(0), reminderSent: false };
	for (const field of [
		"scheduledDeletion",
		"tokensRevokedAt",
		"deletionCancelledAt",
	])
		await assertFails(setDoc(ref, { [field]: marker }));
	await assertSucceeds(setDoc(ref, { displayName: "Synthetic owner" }));
	await assertSucceeds(updateDoc(ref, { displayName: "Updated" }));
	await assertFails(updateDoc(ref, { scheduledDeletion: marker }));
	await env.withSecurityRulesDisabled(async (ctx) =>
		setDoc(doc(ctx.firestore(), "users/rules-owner"), {
			scheduledDeletion: marker,
		}),
	);
	await assertFails(updateDoc(ref, { scheduledDeletion: deleteField() }));
	await assertFails(
		updateDoc(ref, { "scheduledDeletion.deleteAt": Timestamp.now() }),
	);
	await assertFails(setDoc(ref, { displayName: "replacement" }));
	await assertFails(deleteDoc(ref));
	for (const path of ["accountDeletionRequests/forged", "accountDeletionWorker/scan"]) {
		await assertFails(setDoc(doc(db, path), { uid: "rules-owner", state: "pending" }));
		await assertFails(getDoc(doc(db, path)));
	}
	await assertFails(
		setDoc(doc(db, "users/another-user"), { scheduledDeletion: marker }),
	);
	await assertFails(
		setDoc(doc(env.unauthenticatedContext().firestore(), "users/anonymous"), {
			scheduledDeletion: marker,
		}),
	);
});

test("legacy null schedules permit profile updates; destructive claims block further user writes", async () => {
	const ref = doc(
		env.authenticatedContext("rules-lock").firestore(),
		"users/rules-lock",
	);
	await env.withSecurityRulesDisabled(async (ctx) =>
		setDoc(doc(ctx.firestore(), "users/rules-lock"), {
			scheduledDeletion: null,
		}),
	);
	await assertSucceeds(updateDoc(ref, { displayName: "Allowed" }));
	await env.withSecurityRulesDisabled(async (ctx) =>
		updateDoc(doc(ctx.firestore(), "users/rules-lock"), {
			scheduledDeletion: { state: "deleting" },
		}),
	);
	await assertSucceeds(getDoc(ref));
	await assertSucceeds(
		getDoc(
			doc(
				env.authenticatedContext("rules-lock").firestore(),
				"users/rules-lock/notes/retained",
			),
		),
	);
	await assertFails(
		getDoc(
			doc(
				env.authenticatedContext("another-user").firestore(),
				"users/rules-lock/notes/retained",
			),
		),
	);
	await assertFails(updateDoc(ref, { displayName: "Too late" }));
	await assertFails(
		setDoc(
			doc(
				env.authenticatedContext("rules-lock").firestore(),
				"users/rules-lock/devices/new",
			),
			{ status: "approved" },
		),
	);
});

test("deleted shares cannot acquire new orphaned access requests", async () => {
	const sharePath = "shares/deleted-account-share";
	const publicDb = env.unauthenticatedContext().firestore();
	await env.withSecurityRulesDisabled(async (ctx) =>
		setDoc(doc(ctx.firestore(), sharePath), {
			owner_uid: "departed-owner",
			status: "active",
		}),
	);
	await assertSucceeds(
		setDoc(doc(publicDb, `${sharePath}/requests/before`), {
			status: "pending",
		}),
	);
	await env.withSecurityRulesDisabled(async (ctx) =>
		deleteDoc(doc(ctx.firestore(), sharePath)),
	);
	await assertFails(
		setDoc(doc(publicDb, `${sharePath}/requests/after`), { status: "pending" }),
	);
});
