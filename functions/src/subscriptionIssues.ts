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
	status = "open",
	providerKey,
	source,
	type,
	userId = null,
}: {
	details?: Record<string, unknown>;
	status?: "open" | "quarantined";
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
				status,
				actionable: status === "open",
				providerKeyHash: createHash("sha256").update(providerKey).digest("hex"),
				userId,
				details,
				...(status === "quarantined"
					? { quarantinedAt: FieldValue.serverTimestamp() }
					: { quarantinedAt: FieldValue.delete() }),
				resolvedAt: FieldValue.delete(),
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
		.get();
	if (snapshot.empty) return;
	const batch = db.batch();
	let writes = 0;
	for (const issue of snapshot.docs) {
		if (issue.data().status === "resolved") continue;
		batch.update(issue.ref, {
			status: "resolved",
			actionable: false,
			resolvedAt: FieldValue.serverTimestamp(),
			updatedAt: FieldValue.serverTimestamp(),
		});
		writes += 1;
	}
	if (writes > 0) await batch.commit();
}

export async function resolveUserSubscriptionIssues(
	userId: string,
	type: string,
): Promise<void> {
	const snapshot = await db
		.collection(ADMIN_SUBSCRIPTION_ISSUE_COLLECTION)
		.where("userId", "==", userId)
		.where("type", "==", type)
		.get();
	if (snapshot.empty) return;
	const batch = db.batch();
	let writes = 0;
	for (const issue of snapshot.docs) {
		if (issue.data().status === "resolved") continue;
		batch.update(issue.ref, {
			status: "resolved",
			actionable: false,
			resolvedAt: FieldValue.serverTimestamp(),
			updatedAt: FieldValue.serverTimestamp(),
		});
		writes += 1;
	}
	if (writes > 0) await batch.commit();
}
