import { createHash } from "node:crypto";
import { FieldValue } from "firebase-admin/firestore";
import { ADMIN_SUBSCRIPTION_ISSUE_COLLECTION } from "./adminConfig";
import { db } from "./config";

function stableIssueId(type: string, providerKey: string): string {
	return `${type}_${createHash("sha256")
		.update(providerKey)
		.digest("hex")
		.slice(0, 32)}`;
}

export async function recordSubscriptionIssue({
	details = {},
	providerKey,
	source,
	type,
	userId = null,
}: {
	details?: Record<string, unknown>;
	providerKey: string;
	source: string;
	type: string;
	userId?: string | null;
}): Promise<string> {
	const id = stableIssueId(type, providerKey);
	await db
		.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
		.doc(id)
		.set(
			{
				type,
				source,
				status: "open",
				providerKeyHash: createHash("sha256").update(providerKey).digest("hex"),
				userId,
				details,
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);
	return id;
}

export async function resolveSubscriptionIssues(
	providerKey: string,
	source: string,
): Promise<void> {
	const snapshot = await db
		.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
		.where(
			"providerKeyHash",
			"==",
			createHash("sha256").update(providerKey).digest("hex"),
		)
		.where("source", "==", source)
		.where("status", "==", "open")
		.get();
	if (snapshot.empty) return;
	const batch = db.batch();
	for (const issue of snapshot.docs) {
		batch.update(issue.ref, {
			status: "resolved",
			resolvedAt: FieldValue.serverTimestamp(),
			updatedAt: FieldValue.serverTimestamp(),
		});
	}
	await batch.commit();
}

export async function resolveUserSubscriptionIssues(
	userId: string,
	type: string,
): Promise<void> {
	const snapshot = await db
		.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
		.where("userId", "==", userId)
		.where("type", "==", type)
		.where("status", "==", "open")
		.get();
	if (snapshot.empty) return;
	const batch = db.batch();
	for (const issue of snapshot.docs) {
		batch.update(issue.ref, {
			status: "resolved",
			resolvedAt: FieldValue.serverTimestamp(),
			updatedAt: FieldValue.serverTimestamp(),
		});
	}
	await batch.commit();
}
