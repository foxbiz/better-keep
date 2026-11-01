import type { Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

const collections: Record<string, string> = {
	note: "notes",
	label: "labels",
	order: "note_order_contexts",
};

/** Owner-scoped, lazy migration. Never interpret a timezone-less wall clock. */
export async function stampLegacySyncDocument(
	database: Firestore,
	uid: string | undefined,
	input: { kind?: unknown; entityId?: unknown } | undefined,
) {
	if (!uid) throw new HttpsError("unauthenticated", "Sign in required");
	const kind = input?.kind;
	const id = input?.entityId;
	if (
		typeof kind !== "string" ||
		!Object.keys(collections).includes(kind) ||
		typeof id !== "string" ||
		!id ||
		id.length > 256 ||
		id === "." ||
		id === ".." ||
		id.includes("/") ||
		Array.from(id).some((character) => character.charCodeAt(0) < 32)
	) {
		throw new HttpsError("invalid-argument", "Invalid sync document");
	}
	const ref = database.doc(`users/${uid}/${collections[kind]}/${id}`);
	await database.runTransaction(async (transaction) => {
		const snapshot = await transaction.get(ref);
		const data = snapshot.data();
		if (!data || !snapshot.updateTime) {
			throw new HttpsError("not-found", "Sync document no longer exists");
		}
		// The database's original update time is authoritative. Using now would
		// turn an old record into a new edit and defeat newer offline changes.
		if (
			!hasTimestamp(data.updated_at) &&
			!hasTimestamp(data.sync_committed_at)
		) {
			transaction.update(ref, { sync_committed_at: snapshot.updateTime });
		}
	});
	return { ok: true };
}

function hasTimestamp(value: unknown): boolean {
	if (typeof value === "string") {
		return (
			/(?:Z|[+-]\d{2}:?\d{2})$/i.test(value) &&
			Number.isFinite(Date.parse(value))
		);
	}
	return (
		typeof value === "object" &&
		value !== null &&
		"toMillis" in value &&
		typeof value.toMillis === "function" &&
		Number.isFinite(value.toMillis())
	);
}
