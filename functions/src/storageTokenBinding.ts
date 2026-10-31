import { createHmac, timingSafeEqual } from "node:crypto";
import {
	type StorageConnectionContext,
	StorageConnectionError,
} from "./storageConnectionSecurity";

const purpose = "better-keep/storage-token-binding/v1";
function mac(key: string, value: string): string {
	if (!key) throw new StorageConnectionError("unavailable");
	return createHmac("sha256", key).update(value).digest("hex");
}
function identity(
	context: StorageConnectionContext,
	clientId: string,
	generation: number,
) {
	return [
		context.uid,
		context.provider,
		context.connectionId,
		clientId,
		generation,
	];
}
export function storageRefreshBinding(
	key: string,
	context: StorageConnectionContext,
	clientId: string,
	generation: number,
	token: string,
): string {
	return mac(
		key,
		JSON.stringify([
			purpose,
			"token",
			...identity(context, clientId, generation),
			token,
		]),
	);
}

/** A short-lived registration receipt, never a plaintext provider token. */
export function signStorageGrant(
	key: string,
	context: StorageConnectionContext,
	clientId: string,
	generation: number,
	binding: string,
	now = Date.now(),
): string {
	const payload = Buffer.from(
		JSON.stringify([
			...identity(context, clientId, generation),
			binding,
			now + 600000,
		]),
	).toString("base64url");
	return `${payload}.${mac(key, `${purpose}/receipt/${payload}`)}`;
}
export function verifyStorageGrant(
	key: string,
	context: StorageConnectionContext,
	clientId: string,
	generation: number,
	receipt: unknown,
	now = Date.now(),
): string {
	if (typeof receipt !== "string" || receipt.length > 4096)
		throw new StorageConnectionError("denied");
	const [payload, signature, extra] = receipt.split(".");
	if (
		!payload ||
		extra !== undefined ||
		!/^[0-9a-f]{64}$/.test(signature ?? "") ||
		!timingSafeEqual(
			Buffer.from(signature, "hex"),
			Buffer.from(mac(key, `${purpose}/receipt/${payload}`), "hex"),
		)
	)
		throw new StorageConnectionError("denied");
	let fields: unknown;
	try {
		fields = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
	} catch {
		throw new StorageConnectionError("denied");
	}
	if (
		!Array.isArray(fields) ||
		fields.length !== 7 ||
		JSON.stringify(fields.slice(0, 5)) !==
			JSON.stringify(identity(context, clientId, generation)) ||
		typeof fields[5] !== "string" ||
		!/^[0-9a-f]{64}$/.test(fields[5]) ||
		typeof fields[6] !== "number" ||
		!Number.isSafeInteger(fields[6]) ||
		fields[6] <= now ||
		fields[6] > now + 600000
	)
		throw new StorageConnectionError("denied");
	return fields[5];
}
