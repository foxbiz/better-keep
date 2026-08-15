import type { Credential } from "firebase-admin/app";
import type { AdminIndexUserRecord } from "./adminUserIndex";

interface IdentityToolkitProvider {
	providerId?: unknown;
}

interface IdentityToolkitUser {
	localId?: unknown;
	email?: unknown;
	displayName?: unknown;
	photoUrl?: unknown;
	providerUserInfo?: IdentityToolkitProvider[];
	disabled?: unknown;
	emailVerified?: unknown;
	customAttributes?: unknown;
	createdAt?: unknown;
	lastLoginAt?: unknown;
}

interface DownloadAccountResponse {
	users?: IdentityToolkitUser[];
	nextPageToken?: unknown;
}

interface LookupAccountResponse {
	users?: IdentityToolkitUser[];
}

export interface SubscriptionClaimsAuth {
	getUser(uid: string): Promise<{ customClaims?: Record<string, unknown> }>;
	setCustomUserClaims(
		uid: string,
		claims: Record<string, unknown>,
	): Promise<void>;
}

function optionalString(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function millisTimestamp(value: unknown): string | undefined {
	const millis = typeof value === "string" ? Number(value) : Number.NaN;
	if (!Number.isFinite(millis)) return undefined;
	const date = new Date(millis);
	return Number.isNaN(date.getTime()) ? undefined : date.toUTCString();
}

function customClaims(value: unknown): Record<string, unknown> | undefined {
	if (typeof value !== "string" || value.length === 0) return undefined;
	try {
		const parsed = JSON.parse(value) as unknown;
		return parsed && typeof parsed === "object" && !Array.isArray(parsed)
			? (parsed as Record<string, unknown>)
			: undefined;
	} catch {
		return undefined;
	}
}

export function identityToolkitUserRecord(
	user: IdentityToolkitUser,
): AdminIndexUserRecord {
	const uid = optionalString(user.localId);
	if (!uid) throw new Error("Identity Platform returned a user without a UID");
	return {
		uid,
		email: optionalString(user.email),
		displayName: optionalString(user.displayName),
		photoURL: optionalString(user.photoUrl),
		providerData: (user.providerUserInfo ?? [])
			.map((provider) => optionalString(provider.providerId))
			.filter((providerId): providerId is string => providerId !== undefined)
			.map((providerId) => ({ providerId })),
		disabled: user.disabled === true,
		emailVerified: user.emailVerified === true,
		customClaims: customClaims(user.customAttributes),
		metadata: {
			creationTime: millisTimestamp(user.createdAt),
			lastSignInTime: millisTimestamp(user.lastLoginAt),
		},
	};
}

export async function listIdentityToolkitUsers({
	credential,
	projectId,
	pageToken,
	fetchImpl = fetch,
}: {
	credential: Credential;
	projectId: string;
	pageToken?: string;
	fetchImpl?: typeof fetch;
}): Promise<{ users: AdminIndexUserRecord[]; pageToken?: string }> {
	const accessToken = await credential.getAccessToken();
	const endpoint = new URL(
		`https://identitytoolkit.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/accounts:batchGet`,
	);
	endpoint.searchParams.set("maxResults", "1000");
	if (pageToken) endpoint.searchParams.set("nextPageToken", pageToken);
	const response = await fetchImpl(endpoint, {
		headers: {
			Authorization: `Bearer ${accessToken.access_token}`,
			"X-Goog-User-Project": projectId,
		},
	});
	if (!response.ok) {
		throw new Error(
			`Identity Platform user listing failed with HTTP ${response.status}`,
		);
	}
	const payload = (await response.json()) as DownloadAccountResponse;
	return {
		users: (payload.users ?? []).map(identityToolkitUserRecord),
		pageToken: optionalString(payload.nextPageToken),
	};
}

export async function identityToolkitUserExists({
	credential,
	projectId,
	uid,
	fetchImpl = fetch,
}: {
	credential: Credential;
	projectId: string;
	uid: string;
	fetchImpl?: typeof fetch;
}): Promise<boolean> {
	if (!uid.trim()) throw new Error("Identity Platform UID is required");
	const accessToken = await credential.getAccessToken();
	const response = await fetchImpl(
		`https://identitytoolkit.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/accounts:lookup`,
		{
			method: "POST",
			headers: {
				Authorization: `Bearer ${accessToken.access_token}`,
				"Content-Type": "application/json",
				"X-Goog-User-Project": projectId,
			},
			body: JSON.stringify({ localId: [uid] }),
		},
	);
	if (!response.ok) {
		throw new Error(
			`Identity Platform user lookup failed with HTTP ${response.status}`,
		);
	}
	const payload = (await response.json()) as LookupAccountResponse;
	return (payload.users ?? []).some((user) => user.localId === uid);
}

export function identityToolkitClaimsAuth({
	credential,
	projectId,
	fetchImpl = fetch,
}: {
	credential: Credential;
	projectId: string;
	fetchImpl?: typeof fetch;
}): SubscriptionClaimsAuth {
	const endpoint = (operation: "lookup" | "update") =>
		`https://identitytoolkit.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/accounts:${operation}`;
	const request = async (
		operation: "lookup" | "update",
		body: Record<string, unknown>,
	): Promise<LookupAccountResponse> => {
		const accessToken = await credential.getAccessToken();
		const response = await fetchImpl(endpoint(operation), {
			method: "POST",
			headers: {
				Authorization: `Bearer ${accessToken.access_token}`,
				"Content-Type": "application/json",
				"X-Goog-User-Project": projectId,
			},
			body: JSON.stringify(body),
		});
		if (!response.ok) {
			throw new Error(
				`Identity Platform claims ${operation} failed with HTTP ${response.status}`,
			);
		}
		return (await response.json()) as LookupAccountResponse;
	};
	return {
		async getUser(uid) {
			if (!uid.trim()) throw new Error("Identity Platform UID is required");
			const payload = await request("lookup", { localId: [uid] });
			const user = (payload.users ?? []).find(
				(candidate) => candidate.localId === uid,
			);
			if (!user) {
				const error = new Error("Identity Platform user was not found");
				Object.assign(error, { code: "auth/user-not-found" });
				throw error;
			}
			return { customClaims: customClaims(user.customAttributes) };
		},
		async setCustomUserClaims(uid, claims) {
			if (!uid.trim()) throw new Error("Identity Platform UID is required");
			await request("update", {
				customAttributes: JSON.stringify(claims),
				localId: uid,
			});
		},
	};
}
