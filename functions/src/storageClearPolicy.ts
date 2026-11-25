import {
	createHash,
	randomBytes,
	randomInt,
	timingSafeEqual,
} from "node:crypto";
import { StorageConnectionError } from "./storageConnectionSecurity";

export interface StorageClearChallenge {
	id: string;
	hash: string;
	generation: number;
	libraryId: string;
	epoch: string;
	createdAt: number;
	expiresAt: number;
	attempts: number;
}
export interface StorageClearOperation {
	id: string;
	deviceId: string;
	epoch: string;
}
export function clearCodeHash(id: string, code: string): string {
	return createHash("sha256")
		.update(`better-keep/clear-storage/v1/${id}/${code}`)
		.digest("hex");
}
export function newClearChallenge(
	generation: number,
	libraryId: string,
	epoch: string,
	now: number,
) {
	const code = randomInt(100000, 1000000).toString();
	const id = randomBytes(32).toString("hex");
	const challenge: StorageClearChallenge = {
		id,
		hash: clearCodeHash(id, code),
		generation,
		libraryId,
		epoch,
		createdAt: now,
		expiresAt: now + 600000,
		attempts: 0,
	};
	return { code, challenge };
}
export function matchesClearCode(
	challenge: StorageClearChallenge,
	id: unknown,
	code: unknown,
	now: number,
) {
	if (
		challenge.id !== id ||
		typeof code !== "string" ||
		!/^\d{6}$/.test(code) ||
		challenge.expiresAt <= now ||
		challenge.attempts >= 5
	)
		return false;
	const expected = Buffer.from(challenge.hash, "hex");
	const actual = Buffer.from(clearCodeHash(challenge.id, code), "hex");
	return expected.length === actual.length && timingSafeEqual(expected, actual);
}
export function requireClearDevice(deviceId: string | undefined): string {
	if (!deviceId) throw new StorageConnectionError("denied");
	return deviceId;
}
