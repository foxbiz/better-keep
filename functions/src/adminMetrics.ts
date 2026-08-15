import { FieldPath, FieldValue } from "firebase-admin/firestore";
import {
	ADMIN_METRICS_COLLECTION,
	type PaidSubscriptionSource,
} from "./adminConfig";
import { db } from "./config";

export function mergedRevenueProviderStatus(
	data: Record<string, unknown> | null | undefined,
): Record<string, unknown> {
	if (!data) return {};
	const nested =
		data.revenueProviderStatus &&
		typeof data.revenueProviderStatus === "object" &&
		!Array.isArray(data.revenueProviderStatus)
			? (data.revenueProviderStatus as Record<string, unknown>)
			: {};
	const legacy = Object.fromEntries(
		Object.entries(data)
			.filter(([key]) => key.startsWith("revenueProviderStatus."))
			.map(([key, value]) => [
				key.slice("revenueProviderStatus.".length),
				value,
			]),
	);
	return { ...legacy, ...nested };
}

export async function setRevenueProviderStatus(
	provider: PaidSubscriptionSource,
	status: Record<string, unknown>,
): Promise<void> {
	await db
		.collection(ADMIN_METRICS_COLLECTION)
		.doc("current")
		.set(
			{
				revenueProviderStatus: {
					[provider]: {
						...status,
						updatedAt: FieldValue.serverTimestamp(),
					},
				},
			},
			{ merge: true },
		);
}

export async function migrateLegacyRevenueProviderStatus(): Promise<number> {
	const ref = db.collection(ADMIN_METRICS_COLLECTION).doc("current");
	const snapshot = await ref.get();
	if (!snapshot.exists) return 0;
	const data = snapshot.data() ?? {};
	const legacyKeys = Object.keys(data).filter((key) =>
		key.startsWith("revenueProviderStatus."),
	);
	if (legacyKeys.length === 0) return 0;
	await ref.set(
		{ revenueProviderStatus: mergedRevenueProviderStatus(data) },
		{ merge: true },
	);
	for (const key of legacyKeys) {
		await ref.update(new FieldPath(key), FieldValue.delete());
	}
	return legacyKeys.length;
}
