import { FieldPath, Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import {
	claimDeletion,
	finishDeletion,
	recordDeletionAuthInvalidation,
	renewDeletionLease,
} from "../accountDeletionLifecycle";
import { ADMIN_USER_COLLECTION } from "../adminConfig";
import { auth, db, storage } from "../config";
import { deleteStorageOAuthSessions } from "../storageAccountLifecycle";

export default onSchedule(
	{
		schedule: "0 2 * * *",
		timeZone: "UTC",
		retryCount: 5,
		maxInstances: 1,
		concurrency: 1,
		timeoutSeconds: 540,
		minBackoffSeconds: 60,
		maxBackoffSeconds: 3600,
	},
	async () => {
		// This stops new AND partially completed deletions. Never silently drain on disable.
		if (process.env.ACCOUNT_DELETION_ENABLED !== "true") {
			console.warn("Automatic account deletion is disabled");
			return;
		}
		const now = Timestamp.now();
		// Persist scan position so held requests cannot starve later eligible accounts.
		const checkpointRef = db.collection("accountDeletionWorker").doc("scan");
		const checkpoint = (await checkpointRef.get()).data();
		let cursor =
			checkpoint?.deleteAt instanceof Timestamp &&
			typeof checkpoint.uid === "string"
				? {
						deleteAt: checkpoint.deleteAt as Timestamp,
						uid: checkpoint.uid as string,
					}
				: null;
		const query = db
			.collection("users")
			.where("scheduledDeletion.deleteAt", "<=", now)
			.orderBy("scheduledDeletion.deleteAt")
			.orderBy(FieldPath.documentId())
			.limit(100);
		const stopAt = Date.now() + 480_000;
		let claimed = 0;
		const results = {
			processed: 0,
			succeeded: 0,
			failed: 0,
			held: 0,
			waitingForTokens: 0,
		};
		scan: while (Date.now() < stopAt && claimed < 25) {
			const snapshot = await (cursor
				? query.startAfter(cursor.deleteAt, cursor.uid)
				: query
			).get();
			if (snapshot.empty) {
				cursor = null;
				break;
			}
			for (const doc of snapshot.docs) {
				if (Date.now() >= stopAt || claimed >= 25) break scan;
				cursor = {
					deleteAt: doc.data().scheduledDeletion.deleteAt,
					uid: doc.id,
				};
				const userId = doc.id;
				results.processed++;
				try {
					const requestId = doc.data().scheduledDeletion?.requestId;
					if (typeof requestId !== "string") {
						results.held++;
						console.warn("Holding legacy deletion request for review", {
							userId,
						});
						continue;
					}
					const record = await auth.getUser(userId).catch((error) => {
						if (!isNotFoundError(error)) throw error;
						return null;
					});
					const leaseId = await claimDeletion(
						db,
						userId,
						requestId,
						Date.parse(record?.metadata.lastSignInTime ?? ""),
						Timestamp.now(),
					);
					if (!leaseId) {
						results.held++;
						console.warn("Holding deletion request", {
							userId,
							requestId,
							reason: record
								? "proof-sign-in-or-lease-check"
								: "missing-auth-user",
						});
						continue;
					}
					claimed++;
					// Advance before external work so a timeout cannot monopolize the scan.
					await checkpointRef.set(cursor);
					// Revocation alone does not invalidate existing ID tokens in Storage rules.
					// Disable refresh/sign-in, then wait out token lifetime before purging any data.
					try {
						await auth.updateUser(userId, { disabled: true });
						await auth.revokeRefreshTokens(userId);
					} catch (error) {
						if (!isNotFoundError(error)) throw error;
					}
					if (
						!(await recordDeletionAuthInvalidation(
							db,
							userId,
							requestId,
							leaseId,
							record == null || record.disabled,
						))
					) {
						results.waitingForTokens++;
						continue;
					}
					await deleteUserCompletely(userId, requestId, leaseId, stopAt);
					results.succeeded++;
				} catch (error) {
					results.failed++;
					console.error(
						"Account deletion failed; retaining claim for recovery",
						{ userId, error },
					);
				}
			}
		}
		if (cursor) await checkpointRef.set(cursor);
		else await checkpointRef.delete();
		console.log("Deletion run complete", results);
		if (results.failed > 0) {
			throw new Error(
				`${results.failed} scheduled account deletion(s) failed and remain queued`,
			);
		}
	},
);

async function deleteUserCompletely(
	userId: string,
	requestId: string,
	leaseId: string,
	stopAt: number,
): Promise<void> {
	const guardLease = async () => {
		if (Date.now() >= stopAt)
			throw new Error("Deletion run time budget exhausted");
		await renewDeletionLease(db, userId, leaseId);
	};
	await executeUserDeletion(userId, {
		guardLease,
		deleteStorageOAuthSessions: () => deleteStorageOAuthSessions(db, userId),
		deleteSubcollections: async () => {
			const subcollections = [
				...(await db.collection("users").doc(userId).listCollections()),
				...(await db
					.collection(ADMIN_USER_COLLECTION)
					.doc(userId)
					.listCollections()),
			];
			for (const subcollection of subcollections) {
				await guardLease();
				await db.recursiveDelete(subcollection);
			}
			// Hard note deletes do not invoke the update-only share revocation trigger.
			const shares = db
				.collection("shares")
				.where("owner_uid", "==", userId)
				.limit(100);
			while (true) {
				const page = await shares.get();
				if (page.empty) break;
				for (const share of page.docs) {
					await guardLease();
					await db.recursiveDelete(share.ref);
				}
			}
		},
		deleteStorage: async () => {
			for (const prefix of [`users/${userId}/`, `shares/${userId}/`]) {
				// Re-fetch the first bounded page after deleting it; no offset skips.
				while (true) {
					const [files] = await storage
						.bucket()
						.getFiles({ prefix, maxResults: 100, autoPaginate: false });
					if (files.length === 0) break;
					for (const file of files) {
						await guardLease();
						try {
							await file.delete();
						} catch (error) {
							if (!isNotFoundError(error)) throw error;
						}
					}
				}
			}
		},
		deleteAuthUser: async () => {
			try {
				await auth.deleteUser(userId);
			} catch (error) {
				if (!isNotFoundError(error)) throw error;
			}
		},
		deleteFirestoreRoots: () =>
			finishDeletion(db, userId, requestId, leaseId, ADMIN_USER_COLLECTION),
	});
}

export interface UserDeletionOperations {
	guardLease?: () => Promise<void>;
	deleteStorageOAuthSessions: () => Promise<void>;
	deleteSubcollections: () => Promise<void>;
	deleteStorage: () => Promise<void>;
	deleteAuthUser: () => Promise<void>;
	deleteFirestoreRoots: () => Promise<void>;
}

export function isNotFoundError(error: unknown): boolean {
	const candidate = error as { code?: string | number };
	return (
		candidate?.code === "auth/user-not-found" ||
		candidate?.code === "storage/object-not-found" ||
		candidate?.code === 404
	);
}

export async function executeUserDeletion(
	_userId: string,
	operations: UserDeletionOperations,
): Promise<void> {
	await operations.guardLease?.();
	await operations.deleteStorageOAuthSessions();
	await operations.guardLease?.();
	await operations.deleteSubcollections();
	await operations.guardLease?.();
	await operations.deleteStorage();
	await operations.guardLease?.();
	await operations.deleteAuthUser();
	await operations.guardLease?.();
	await operations.deleteFirestoreRoots();
}
