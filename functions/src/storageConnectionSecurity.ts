import { createHash, timingSafeEqual } from "node:crypto";

export type StorageProvider =
	| "google_drive"
	| "dropbox"
	| "nextcloud"
	| "webdav";
export interface StorageConnectionContext {
	uid: string;
	connectionId: string;
	provider: StorageProvider;
	deviceId?: string;
}
export class StorageConnectionError extends Error {
	constructor(
		readonly kind:
			| "denied"
			| "busy"
			| "reconnect_required"
			| "unavailable"
			| "invalid",
	) {
		super(`Storage connection ${kind}`);
	}
}
/** Retains the original capability hash domain for fresh-consent replacement.
 * This hash authorizes ciphertext mutations; it cannot decrypt credentials. */
export function storageCapabilityHash(
	context: StorageConnectionContext,
	capability: string,
): string {
	if (
		!context.uid ||
		context.uid.length > 128 ||
		!/^[-a-zA-Z0-9_]{1,128}$/.test(context.connectionId) ||
		!["google_drive", "dropbox", "nextcloud", "webdav"].includes(
			context.provider,
		) ||
		!/^[A-Za-z0-9_-]{43}$/.test(capability) ||
		Buffer.from(capability, "base64url").length !== 32 ||
		Buffer.from(capability, "base64url").toString("base64url") !== capability
	)
		throw new StorageConnectionError("invalid");
	return createHash("sha256")
		.update(
			JSON.stringify([
				"better-keep/storage-vault",
				1,
				"capability-v1",
				context.uid,
				context.connectionId,
				context.provider,
			]),
		)
		.update(capability)
		.digest("hex");
}
export function verifyStorageCapability(
	context: StorageConnectionContext,
	capability: unknown,
	expectedHash: unknown,
): boolean {
	if (
		typeof capability !== "string" ||
		typeof expectedHash !== "string" ||
		!/^[0-9a-f]{64}$/.test(expectedHash)
	)
		return false;
	try {
		return timingSafeEqual(
			Buffer.from(storageCapabilityHash(context, capability), "hex"),
			Buffer.from(expectedHash, "hex"),
		);
	} catch {
		return false;
	}
}
