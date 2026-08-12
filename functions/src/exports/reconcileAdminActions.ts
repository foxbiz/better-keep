import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { ADMIN_AUDIT_COLLECTION } from "../adminConfig";
import { syncAdminUserIndex } from "../adminUserIndex";
import { auth, db } from "../config";

export function revokedAfter(
	tokensValidAfterTime: string | undefined,
	requestedAt: Timestamp,
): boolean {
	if (!tokensValidAfterTime) return false;
	const validAfter = new Date(tokensValidAfterTime).getTime();
	return (
		Number.isFinite(validAfter) && validAfter >= requestedAt.toMillis() - 1000
	);
}

export default onSchedule(
	{ schedule: "every 10 minutes", timeZone: "UTC" },
	async () => {
		const staleBefore = Timestamp.fromMillis(Date.now() - 5 * 60 * 1000);
		const snapshot = await db
			.collection(ADMIN_AUDIT_COLLECTION)
			.where("status", "==", "pending")
			.where("requestedAt", "<=", staleBefore)
			.orderBy("requestedAt")
			.limit(100)
			.get();
		for (const audit of snapshot.docs) {
			const data = audit.data();
			const uid = typeof data.targetUid === "string" ? data.targetUid : "";
			const requestedAt = data.requestedAt;
			if (!uid || !(requestedAt instanceof Timestamp)) {
				await audit.ref.update({
					status: "needsAttention",
					completedAt: Timestamp.now(),
				});
				continue;
			}
			try {
				const user = await auth.getUser(uid);
				const action = data.action;
				const requiresRevocation =
					(data.metadata as Record<string, unknown> | undefined)
						?.revokeSessions === true;
				const matches =
					action === "user.disabled"
						? user.disabled &&
							(!requiresRevocation ||
								revokedAfter(user.tokensValidAfterTime, requestedAt))
						: action === "user.enabled"
							? !user.disabled
							: action === "user.sessions_revoked"
								? revokedAfter(user.tokensValidAfterTime, requestedAt)
								: false;
				if (!matches) {
					await audit.ref.update({
						status: "needsAttention",
						completedAt: Timestamp.now(),
					});
					continue;
				}
				await syncAdminUserIndex(uid);
				await audit.ref.update({
					status: "succeeded",
					result:
						action === "user.sessions_revoked"
							? { success: true }
							: { success: true, disabled: user.disabled },
					completedAt: Timestamp.now(),
					reconciled: true,
				});
			} catch (error) {
				console.error(`Failed to reconcile admin action ${audit.id}:`, error);
			}
		}
	},
);
