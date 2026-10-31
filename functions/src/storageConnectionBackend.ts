import { FieldValue } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { type CallableOptions, HttpsError } from "firebase-functions/v2/https";
import { auth, db, emailPassword, googleDriveClientSecret } from "./config";
import { generateOtpEmailHtml, generateOtpEmailText } from "./email_templates";
import {
	type EncryptedConnectionRepository,
	EncryptedStorageConnectionService,
	type StoredConnection,
} from "./encryptedStorageConnectionService";
import {
	type AuthenticatedCallableRequest,
	onNonReviewCall,
} from "./nonReviewCallable";
import {
	requireActiveStorageAccount,
	requireStorageAccountTransaction,
} from "./storageAccountLifecycle";
import type { StorageConnectionContext } from "./storageConnectionSecurity";
import { StorageConnectionError } from "./storageConnectionSecurity";
import { verifyStorageGrant } from "./storageTokenBinding";
import { sendEmail } from "./utils";

type StorageRequest = Record<string, unknown>;
const repository: EncryptedConnectionRepository = {
	async transact(context, mutate) {
		const user = db.collection("users").doc(context.uid);
		const privateRef = user
			.collection("storage_credentials")
			.doc(context.connectionId);
		const publicRef = user
			.collection("storage_connections")
			.doc(context.connectionId);
		return db.runTransaction(async (transaction) => {
			await requireStorageAccountTransaction(db, transaction, context.uid);
			if (
				!context.deviceId ||
				(
					await transaction.get(
						user.collection("devices").doc(context.deviceId),
					)
				).data()?.status !== "approved"
			)
				throw new StorageConnectionError("denied");
			const snapshot = await transaction.get(privateRef);
			const { next, result } = mutate(
				snapshot.exists ? (snapshot.data() as StoredConnection) : null,
			);
			if (
				next &&
				(next.public.state === "clearing" ||
					snapshot.data()?.public?.state === "clearing")
			) {
				const selection = user.collection("sync_settings").doc("firebase");
				if (
					(await transaction.get(selection)).data()?.provider ===
					context.provider
				) {
					transaction.set(selection, {
						provider: "none",
						enabled: false,
						updatedAt: FieldValue.serverTimestamp(),
					});
				}
			}
			if (next) {
				transaction.set(privateRef, next);
				transaction.set(publicRef, next.public);
			}
			return result;
		});
	},
};
const service = new EncryptedStorageConnectionService(repository);

export async function requireStorageSession(
	request: AuthenticatedCallableRequest<StorageRequest>,
): Promise<StorageConnectionContext> {
	const provider = request.data?.provider;
	const deviceId = request.data?.deviceId;
	if (
		(provider !== "google_drive" &&
			provider !== "dropbox" &&
			provider !== "nextcloud" &&
			provider !== "webdav") ||
		typeof deviceId !== "string" ||
		!/^[A-Za-z0-9_-]{1,128}$/.test(deviceId)
	) {
		throw new HttpsError("invalid-argument", "Invalid storage connection");
	}
	const bearer = request.rawRequest
		.get("authorization")
		?.match(/^Bearer (.+)$/i)?.[1];
	if (!bearer) throw new HttpsError("unauthenticated", "Sign in again");
	const token = await auth
		.verifyIdToken(bearer, true)
		.catch((error: unknown) => {
			const code =
				error && typeof error === "object" && "code" in error
					? error.code
					: undefined;
			if (
				[
					"auth/user-not-found",
					"auth/user-disabled",
					"auth/id-token-revoked",
					"auth/id-token-expired",
					"auth/invalid-id-token",
				].includes(code as string)
			) {
				throw new HttpsError("unauthenticated", "Sign in to Better Keep again");
			}
			throw error;
		});
	if (token.uid !== request.auth.uid)
		throw new HttpsError("permission-denied", "Invalid account");
	requireActiveStorageAccount(
		await db.collection("users").doc(token.uid).get(),
	);
	const device = await db
		.collection("users")
		.doc(token.uid)
		.collection("devices")
		.doc(deviceId)
		.get();
	if (device.data()?.status !== "approved")
		throw new HttpsError("permission-denied", "Device approval required");
	// The capability is ALSO required for existing connections: device documents
	// are owner-writable and their status alone is not a cryptographic proof.
	return { uid: token.uid, provider, connectionId: provider, deviceId };
}

export async function sanitizedStorageAction<T>(
	action: () => Promise<T>,
	diagnostic?: () => { operation: string; stage: string },
): Promise<T> {
	try {
		return await action();
	} catch (error) {
		// Log only controlled codes and stages, never error messages, requests,
		// provider responses or credentials. Unexpected errors were otherwise lost.
		const rawCode =
			error && typeof error === "object" && "code" in error
				? error.code
				: undefined;
		const knownCodes: unknown[] = [
			"auth/id-token-expired",
			"auth/id-token-revoked",
			"auth/user-disabled",
			"auth/user-not-found",
			"auth/argument-error",
			"auth/invalid-id-token",
			"auth/invalid-credential",
			"auth/internal-error",
			"auth/project-not-found",
			"ECONNREFUSED",
			"ENOTFOUND",
			"ETIMEDOUT",
			3,
			4,
			5,
			7,
			9,
			13,
			14,
			16,
		];
		logger.warn("Storage action failed", {
			...diagnostic?.(),
			code:
				error instanceof HttpsError
					? error.code
					: error instanceof StorageConnectionError
						? error.kind
						: knownCodes.includes(rawCode)
							? rawCode
							: "unexpected",
		});
		if (error instanceof HttpsError) throw error;
		if (error instanceof StorageConnectionError) {
			const code = {
				denied: "permission-denied",
				busy: "aborted",
				reconnect_required: "failed-precondition",
				unavailable: "unavailable",
				invalid: "invalid-argument",
			} as const;
			throw new HttpsError(code[error.kind], error.message, {
				reason: error.kind,
			});
		}
		throw new HttpsError("unavailable", "Storage connection is unavailable");
	}
}

function text(value: unknown): string {
	if (typeof value !== "string" || value.length > 100000)
		throw new StorageConnectionError("invalid");
	return value;
}
function integer(value: unknown): number {
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0)
		throw new StorageConnectionError("invalid");
	return value;
}
function endpoint(
	keys: string[],
	action: (
		context: StorageConnectionContext,
		data: StorageRequest,
	) => Promise<unknown>,
	options: CallableOptions = {},
) {
	return onNonReviewCall(
		options,
		(request: AuthenticatedCallableRequest<StorageRequest>) =>
			sanitizedStorageAction(async () => {
				// Reject old clients and accidental plaintext fields before any persistence.
				if (
					!request.data ||
					Object.keys(request.data).some(
						(key) =>
							!["provider", "deviceId", "capability", ...keys].includes(key),
					)
				)
					throw new StorageConnectionError("invalid");
				const context = await requireStorageSession(request);
				return action(context, request.data);
			}),
	);
}
export const registerEncryptedStorageConnection = endpoint(
	[
		"previousCapability",
		"exchangeProof",
		"encryptedCapability",
		"encryptedCredentials",
		"libraryId",
		"clientId",
		"generation",
	],
	(context, d) => {
		// The confidential exchange client cannot be registered without its receipt.
		// Direct provider grants use other client IDs and retain the existing flow.
		if (
			context.provider === "google_drive" &&
			d.clientId === process.env.GOOGLE_DRIVE_CLIENT_ID?.trim() &&
			d.exchangeProof === undefined
		)
			throw new StorageConnectionError("reconnect_required");
		return service.register(context, {
			...(d.exchangeProof === undefined
				? {}
				: {
						refreshBinding: verifyStorageGrant(
							context.provider === "google_drive"
								? googleDriveClientSecret.value()
								: "",
							context,
							text(d.clientId),
							integer(d.generation),
							d.exchangeProof,
						),
					}),
			capability: text(d.capability),
			previousCapability:
				d.previousCapability === undefined
					? undefined
					: text(d.previousCapability),
			encryptedCapability: text(d.encryptedCapability),
			encryptedCredentials: text(d.encryptedCredentials),
			libraryId: text(d.libraryId),
			clientId: text(d.clientId),
			generation: integer(d.generation),
		});
	},
	{ secrets: [googleDriveClientSecret] },
);
export const getEncryptedStorageCredentials = endpoint(["generation"], (c, d) =>
	service.read(c, text(d.capability), integer(d.generation)),
);
export const acquireStorageRefreshLease = endpoint(
	["generation", "revision"],
	(c, d) =>
		service.acquire(
			c,
			text(d.capability),
			integer(d.generation),
			integer(d.revision),
		),
);
export const finishStorageRefresh = endpoint(
	["generation", "revision", "leaseId", "fence", "encryptedCredentials"],
	(c, d) =>
		service.finish(c, text(d.capability), {
			generation: integer(d.generation),
			revision: integer(d.revision),
			leaseId: text(d.leaseId),
			fence: integer(d.fence),
			encryptedCredentials: text(d.encryptedCredentials),
		}),
);
export const releaseStorageRefreshLease = endpoint(["leaseId"], (c, d) =>
	service.release(c, text(d.capability), text(d.leaseId)),
);
export const setStorageConnectionEnabled = endpoint(["enabled"], (c, d) => {
	if (typeof d.enabled !== "boolean")
		throw new StorageConnectionError("invalid");
	return service.setEnabled(c, text(d.capability), d.enabled);
});
export const beginStorageDisconnect = endpoint([], (c, d) =>
	service.disconnect(c, text(d.capability), true),
);
export const disconnectStorageConnection = endpoint([], (c, d) =>
	service.disconnect(c, text(d.capability), false),
);

// Keep deployed names as fail-closed tombstones until the rollout removes them.
const retired = () => {
	throw new HttpsError(
		"failed-precondition",
		"Update Better Keep and reconnect storage",
	);
};
export const getStorageAccess = onNonReviewCall(retired);
export const connectNextcloudStorage = onNonReviewCall(retired);

export const requestStorageClearOtp = onNonReviewCall(
	{ secrets: [emailPassword] },
	(request: AuthenticatedCallableRequest<StorageRequest>) =>
		sanitizedStorageAction(async () => {
			if (
				!request.data ||
				Object.keys(request.data).some(
					(key) => !["provider", "deviceId", "capability"].includes(key),
				)
			)
				throw new StorageConnectionError("invalid");
			const context = await requireStorageSession(request);
			const user = await auth.getUser(context.uid);
			if (!user.email || !user.emailVerified)
				throw new HttpsError(
					"failed-precondition",
					"A verified account email is required",
				);
			const { code, requestId } = await service.requestClear(
				context,
				text(request.data.capability),
			);
			const config = {
				title: "Clear synced data",
				description: `Remove this Better Keep account's synced data from ${context.provider}. Notes on your devices will remain. Sync will be turned off. Enter this code in the app to confirm:`,
				otp: code,
				theme: "danger" as const,
				securityNote:
					"Data that exists only in this provider will be lost. Never share this code. Ignore this email if you did not request it.",
			};
			await sendEmail({
				from: `"${process.env.EMAIL_NAME}" <${process.env.EMAIL_FROM}>`,
				to: user.email,
				subject: "Clear synced data verification - Better Keep",
				html: generateOtpEmailHtml(config),
				text: generateOtpEmailText(config),
			});
			return {
				requestId,
				email: user.email.replace(
					/^(.)([^@]*)(@.*)$/,
					(_, start, middle, end) =>
						start + "*".repeat(Math.max(1, Math.min(middle.length, 5))) + end,
				),
			};
		}),
);
export const beginStorageClear = endpoint(["requestId", "code"], (c, d) =>
	service.beginClear(c, text(d.capability), text(d.requestId), text(d.code)),
);
export const finishStorageClear = endpoint(["operationId"], (c, d) =>
	service.finishClear(c, text(d.capability), text(d.operationId)),
);

export const storageTokenExchangeGeneration =
	service.tokenExchangeGeneration.bind(service);
export const beginStorageTokenRefresh = service.beginTokenRefresh.bind(service);
export const completeStorageTokenRefresh =
	service.completeTokenRefresh.bind(service);
