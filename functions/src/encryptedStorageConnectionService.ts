import { randomBytes, timingSafeEqual } from "node:crypto";
import {
	matchesClearCode,
	newClearChallenge,
	requireClearDevice,
	type StorageClearChallenge,
	type StorageClearOperation,
} from "./storageClearPolicy";
import {
	type StorageConnectionContext,
	StorageConnectionError,
	storageCapabilityHash,
	verifyStorageCapability,
} from "./storageConnectionSecurity";

export interface EncryptedConnectionPublic {
	provider: string;
	connectionId: string;
	libraryId: string;
	accountLabel: string;
	encryptedCapability: string;
	generation: number;
	enabled: boolean;
	state: "ready" | "disconnecting" | "disconnected" | "clearing";
	updatedAt: number;
	credentialVersion: 2 | 3;
	storageEpoch?: string;
	clearOperationId?: string;
	clientId: string;
}
export interface TokenRefreshInput {
	generation: number;
	revision: number;
	leaseId: string;
	fence: number;
	clientId: string;
	binding: string;
}
export interface EncryptedConnectionRecord {
	clearChallenge?: StorageClearChallenge | null;
	clearing?: StorageClearOperation | null;
	completedClear?: StorageClearOperation | null;
	version: 2;
	public: EncryptedConnectionPublic;
	capabilityHash: string;
	encryptedCredentials: string | null;
	revision: number;
	fence: number;
	refreshBinding?: string;
	lease: {
		id: string;
		fence: number;
		expiresAt: number;
		exchange?: { id: string; nextBinding: string | null };
	} | null;
}
// Only these fields from old records are needed to fence a fresh-consent
// replacement. Old vault ciphertext is never read or decrypted.
export interface LegacyConnectionRecord {
	public: {
		generation: number;
		updatedAt: number;
		libraryId?: string;
		encryptedCapability?: string;
	};
	capabilityHash: string;
}
export type StoredConnection =
	| EncryptedConnectionRecord
	| LegacyConnectionRecord;
export interface EncryptedConnectionRepository {
	transact<T>(
		context: StorageConnectionContext,
		mutate: (current: StoredConnection | null) => {
			next?: EncryptedConnectionRecord;
			result: T;
		},
	): Promise<T>;
}
export interface EncryptedRegistration {
	// Server-verified receipt fingerprint only; never accepted directly from a caller.
	refreshBinding?: string;
	capability: string;
	previousCapability?: string;
	encryptedCapability: string;
	encryptedCredentials: string;
	libraryId: string;
	clientId: string;
	generation: number;
}

function ciphertext(value: unknown): asserts value is string {
	if (
		typeof value !== "string" ||
		value.length < 64 ||
		value.length > 100000 ||
		Buffer.from(value, "base64").toString("base64") !== value
	) {
		throw new StorageConnectionError("invalid");
	}
}
function authorize(
	context: StorageConnectionContext,
	current: StoredConnection | null,
	capability: unknown,
): asserts current is StoredConnection {
	if (
		!current ||
		!verifyStorageCapability(context, capability, current.capabilityHash)
	)
		throw new StorageConnectionError("denied");
}
function encrypted(
	current: StoredConnection,
): asserts current is EncryptedConnectionRecord {
	if (!("version" in current) || current.version !== 2)
		throw new StorageConnectionError("reconnect_required");
}
function material(current: EncryptedConnectionRecord) {
	if (!current.encryptedCredentials)
		throw new StorageConnectionError("reconnect_required");
	return {
		encryptedCredentials: current.encryptedCredentials,
		generation: current.public.generation,
		clientId: current.public.clientId,
		revision: current.revision,
	};
}

/** Coordinates ciphertext only. No token endpoint, vault key or decryptor. */
export class EncryptedStorageConnectionService {
	constructor(
		private readonly repository: EncryptedConnectionRepository,
		private readonly now: () => number = Date.now,
	) {}

	register(context: StorageConnectionContext, input: EncryptedRegistration) {
		ciphertext(input.encryptedCredentials);
		ciphertext(input.encryptedCapability);
		if (
			!/^[0-9a-f]{64}$/.test(input.libraryId) ||
			typeof input.clientId !== "string" ||
			input.clientId.length > 512 ||
			(!["nextcloud", "webdav"].includes(context.provider) &&
				!input.clientId) ||
			!Number.isSafeInteger(input.generation) ||
			input.generation < 1
		)
			throw new StorageConnectionError("invalid");
		const capabilityHash = storageCapabilityHash(context, input.capability);
		return this.repository.transact(context, (current) => {
			if (
				current &&
				"version" in current &&
				current.version === 2 &&
				current.public.generation === input.generation &&
				current.capabilityHash === capabilityHash &&
				current.encryptedCredentials === input.encryptedCredentials &&
				current.public.state === "ready" &&
				current.public.encryptedCapability === input.encryptedCapability &&
				current.public.clientId === input.clientId &&
				current.public.libraryId === input.libraryId &&
				current.refreshBinding === input.refreshBinding
			) {
				return { result: current.public }; // Lost response: same operation, no new generation.
			}
			if (current) authorize(context, current, input.previousCapability);
			if (input.generation !== (current?.public.generation ?? 0) + 1)
				throw new StorageConnectionError("busy");
			if (
				current &&
				"version" in current &&
				(current.public.state === "disconnecting" ||
					current.public.state === "clearing")
			)
				throw new StorageConnectionError("busy");
			const next: EncryptedConnectionRecord = {
				version: 2,
				public: {
					provider: context.provider,
					connectionId: context.connectionId,
					libraryId: input.libraryId,
					accountLabel: "",
					encryptedCapability: input.encryptedCapability,
					generation: input.generation,
					enabled: true,
					state: "ready",
					updatedAt: Math.max(this.now(), (current?.public.updatedAt ?? 0) + 1),
					credentialVersion:
						current && "version" in current
							? current.public.credentialVersion
							: 2,
					storageEpoch:
						current && "version" in current
							? (current.public.storageEpoch ?? "")
							: "",
					clientId: input.clientId,
				},
				capabilityHash,
				...(input.refreshBinding
					? { refreshBinding: input.refreshBinding }
					: {}),
				encryptedCredentials: input.encryptedCredentials,
				revision: 1,
				fence: 0,
				lease: null,
			};
			return { next, result: next.public };
		});
	}

	read(
		context: StorageConnectionContext,
		capability: string,
		generation: number,
	) {
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			if (current.public.generation !== generation)
				throw new StorageConnectionError("denied");
			return { result: material(current) };
		});
	}

	acquire(
		context: StorageConnectionContext,
		capability: string,
		generation: number,
		revision: number,
	) {
		const id = randomBytes(32).toString("base64url");
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			if (
				current.public.generation !== generation ||
				!(
					(current.public.enabled && current.public.state === "ready") ||
					(current.public.state === "clearing" &&
						current.clearing?.deviceId === context.deviceId)
				)
			)
				throw new StorageConnectionError("denied");
			if (revision !== current.revision)
				return {
					result: {
						status: "changed",
						...material(current),
						leaseId: "",
						fence: 0,
					},
				};
			if (current.lease && current.lease.expiresAt > this.now())
				throw new StorageConnectionError("busy");
			const fence = current.fence + 1;
			const next = {
				...current,
				fence,
				lease: { id, fence, expiresAt: this.now() + 60000 },
			};
			return {
				next,
				result: {
					status: "acquired",
					...material(current),
					leaseId: id,
					fence,
				},
			};
		});
	}

	/** Pin initial consent to the next generation without storing credentials. */
	tokenExchangeGeneration(context: StorageConnectionContext) {
		return this.repository.transact(context, (current) => {
			if (
				current &&
				"version" in current &&
				["disconnecting", "clearing"].includes(current.public.state)
			)
				throw new StorageConnectionError("busy");
			return { result: (current?.public.generation ?? 0) + 1 };
		});
	}

	/** Reserve one exchange per lease; validate the token before any provider call. */
	beginTokenRefresh(
		context: StorageConnectionContext,
		capability: string,
		input: TokenRefreshInput,
	) {
		return this.tokenRefresh(context, capability, input);
	}
	completeTokenRefresh(
		context: StorageConnectionContext,
		capability: string,
		input: TokenRefreshInput,
		exchangeId: string,
		nextBinding: string,
	) {
		return this.tokenRefresh(context, capability, input, {
			exchangeId,
			nextBinding,
		});
	}
	private tokenRefresh(
		context: StorageConnectionContext,
		capability: string,
		input: TokenRefreshInput,
		completion?: { exchangeId: string; nextBinding: string },
	) {
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			if (
				current.public.generation !== input.generation ||
				current.public.clientId !== input.clientId ||
				!(
					(current.public.enabled && current.public.state === "ready") ||
					(current.public.state === "clearing" &&
						current.clearing?.deviceId === context.deviceId)
				) ||
				current.revision !== input.revision ||
				current.lease?.id !== input.leaseId ||
				current.lease.fence !== input.fence ||
				current.lease.expiresAt <= this.now()
			)
				throw new StorageConnectionError("denied");
			if (!current.refreshBinding)
				throw new StorageConnectionError("reconnect_required");
			if (
				!/^[0-9a-f]{64}$/.test(input.binding) ||
				!/^[0-9a-f]{64}$/.test(current.refreshBinding) ||
				!timingSafeEqual(
					Buffer.from(current.refreshBinding, "hex"),
					Buffer.from(input.binding, "hex"),
				)
			)
				throw new StorageConnectionError("denied");
			const lease = current.lease;
			if (!lease) throw new StorageConnectionError("denied");
			if (completion) {
				if (
					lease.exchange?.id !== completion.exchangeId ||
					lease.exchange.nextBinding !== null
				)
					throw new StorageConnectionError("denied");
			} else if (lease.exchange) {
				throw new StorageConnectionError("busy");
			}
			const id =
				completion?.exchangeId ?? randomBytes(32).toString("base64url");
			return {
				next: {
					...current,
					lease: {
						...lease,
						exchange: {
							id,
							nextBinding: completion?.nextBinding ?? null,
						},
					},
				},
				result: id,
			};
		});
	}

	finish(
		context: StorageConnectionContext,
		capability: string,
		input: {
			generation: number;
			revision: number;
			leaseId: string;
			fence: number;
			encryptedCredentials: string;
		},
	) {
		ciphertext(input.encryptedCredentials);
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			if (
				current.public.generation !== input.generation ||
				!(
					(current.public.enabled && current.public.state === "ready") ||
					(current.public.state === "clearing" &&
						current.clearing?.deviceId === context.deviceId)
				)
			)
				throw new StorageConnectionError("denied");
			// Idempotent retry after a commit whose response was lost.
			if (
				!current.lease &&
				current.fence === input.fence &&
				current.revision === input.revision + 1 &&
				current.encryptedCredentials === input.encryptedCredentials
			)
				return { result: { revision: current.revision } };
			if (
				current.revision !== input.revision ||
				current.lease?.id !== input.leaseId ||
				current.lease.fence !== input.fence ||
				current.lease.expiresAt <= this.now()
			)
				throw new StorageConnectionError("denied");
			// A rotating token and its ciphertext must advance in the same commit.
			// In-flight/missing exchange results cannot be committed by another request.
			const nextBinding = current.lease?.exchange?.nextBinding;
			if (current.refreshBinding && !nextBinding)
				throw new StorageConnectionError("busy");
			const next = {
				...current,
				...(nextBinding ? { refreshBinding: nextBinding } : {}),
				encryptedCredentials: input.encryptedCredentials,
				revision: current.revision + 1,
				lease: null,
			};
			return { next, result: { revision: next.revision } };
		});
	}

	release(
		context: StorageConnectionContext,
		capability: string,
		leaseId: string,
	) {
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			return {
				...(current.lease?.id === leaseId
					? { next: { ...current, lease: null } }
					: {}),
				result: { success: true },
			};
		});
	}

	async requestClear(context: StorageConnectionContext, capability: string) {
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			if (!["ready", "clearing"].includes(current.public.state))
				throw new StorageConnectionError("busy");
			const now = this.now();
			if (
				current.clearChallenge &&
				now - current.clearChallenge.createdAt < 60000
			)
				throw new StorageConnectionError("busy");
			const { code, challenge } = newClearChallenge(
				current.public.generation,
				current.public.libraryId,
				current.public.storageEpoch ?? "",
				now,
			);
			return {
				next: { ...current, clearChallenge: challenge },
				result: { code, requestId: challenge.id },
			};
		});
	}
	async beginClear(
		context: StorageConnectionContext,
		capability: string,
		requestId: string,
		code: string,
	) {
		const result = await this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			if (current.lease && current.lease.expiresAt > this.now())
				throw new StorageConnectionError("busy");
			const challenge = current.clearChallenge;
			const epoch = current.public.storageEpoch ?? "";
			if (
				!challenge ||
				!["ready", "clearing"].includes(current.public.state) ||
				challenge.generation !== current.public.generation ||
				challenge.libraryId !== current.public.libraryId ||
				challenge.epoch !== epoch
			)
				throw new StorageConnectionError("denied");
			if (!matchesClearCode(challenge, requestId, code, this.now())) {
				return {
					next: {
						...current,
						clearChallenge: {
							...challenge,
							attempts: Math.min(5, challenge.attempts + 1),
						},
					},
					result: { ok: false, operationId: "" },
				};
			}
			const operation = {
				id: randomBytes(32).toString("hex"),
				deviceId: requireClearDevice(context.deviceId),
				epoch,
			};
			return {
				next: {
					...current,
					clearChallenge: null,
					clearing: operation,
					fence: current.fence + 1,
					lease: null,
					public: {
						...current.public,
						enabled: false,
						state: "clearing",
						clearOperationId: operation.id,
						updatedAt: Math.max(this.now(), current.public.updatedAt + 1),
					},
				},
				result: { ok: true, operationId: operation.id },
			};
		});
		if (!result.ok) throw new StorageConnectionError("denied");
		return result;
	}
	finishClear(
		context: StorageConnectionContext,
		capability: string,
		operationId: string,
	) {
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			if (
				current.completedClear?.id === operationId &&
				current.completedClear.deviceId === context.deviceId
			)
				return { result: { success: true } };
			if (
				current.public.state !== "clearing" ||
				current.clearing?.id !== operationId ||
				current.clearing.deviceId !== context.deviceId
			)
				throw new StorageConnectionError("denied");
			return {
				next: {
					...current,
					completedClear: current.clearing,
					clearing: null,
					clearChallenge: null,
					fence: current.fence + 1,
					lease: null,
					public: {
						...current.public,
						enabled: false,
						state: "ready",
						credentialVersion: 3,
						storageEpoch: randomBytes(32).toString("hex"),
						clearOperationId: "",
						updatedAt: Math.max(this.now(), current.public.updatedAt + 1),
					},
				},
				result: { success: true },
			};
		});
	}

	setEnabled(
		context: StorageConnectionContext,
		capability: string,
		enabled: boolean,
	) {
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			encrypted(current);
			if (current.public.state !== "ready")
				throw new StorageConnectionError("reconnect_required");
			const next = {
				...current,
				fence: current.fence + 1,
				lease: null,
				public: {
					...current.public,
					enabled,
					updatedAt: Math.max(this.now(), current.public.updatedAt + 1),
				},
			};
			return { next, result: { success: true } };
		});
	}

	disconnect(
		context: StorageConnectionContext,
		capability: string,
		begin: boolean,
	) {
		return this.repository.transact(context, (current) => {
			authorize(context, current, capability);
			if ("version" in current && current.public.state === "clearing")
				throw new StorageConnectionError("busy");
			if (!("version" in current)) {
				// Retire legacy records without opening or copying vault ciphertext.
				const next: EncryptedConnectionRecord = {
					version: 2,
					capabilityHash: current.capabilityHash,
					encryptedCredentials: null,
					revision: 0,
					fence: 1,
					lease: null,
					public: {
						provider: context.provider,
						connectionId: context.connectionId,
						libraryId: current.public.libraryId ?? "",
						encryptedCapability: current.public.encryptedCapability ?? "",
						accountLabel: "",
						generation: current.public.generation,
						enabled: false,
						state: begin ? "disconnecting" : "disconnected",
						credentialVersion: 2,
						clientId: "",
						updatedAt: Math.max(this.now(), current.public.updatedAt + 1),
					},
				};
				return { next, result: { success: true } };
			}
			const next: EncryptedConnectionRecord = {
				...current,
				fence: current.fence + 1,
				lease: null,
				encryptedCredentials: begin ? current.encryptedCredentials : null,
				public: {
					...current.public,
					enabled: false,
					state: begin ? "disconnecting" : "disconnected",
					updatedAt: Math.max(this.now(), current.public.updatedAt + 1),
				},
			};
			return { next, result: { success: true } };
		});
	}
}
