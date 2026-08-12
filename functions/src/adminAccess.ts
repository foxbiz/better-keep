import { HttpsError } from "firebase-functions/v2/https";
import {
	ADMIN_ACCESS_CLAIM,
	ADMIN_RECENT_AUTH_SECONDS,
	ADMIN_TOTP_FACTOR,
	configuredAdminUid,
} from "./adminConfig";

export interface AdminAuthData {
	uid: string;
	token: Record<string, unknown>;
}

function firebaseClaim(token: Record<string, unknown>, key: string): unknown {
	const firebaseClaim = token.firebase;
	if (!firebaseClaim || typeof firebaseClaim !== "object") return null;
	return (firebaseClaim as Record<string, unknown>)[key];
}

export function hasAdminAccess(
	authData: AdminAuthData | null | undefined,
): authData is AdminAuthData {
	if (!authData) return false;
	const adminUid = configuredAdminUid();
	return (
		adminUid.length > 0 &&
		authData.uid === adminUid &&
		authData.token.email_verified === true &&
		authData.token[ADMIN_ACCESS_CLAIM] === true &&
		firebaseClaim(authData.token, "sign_in_provider") === "password" &&
		firebaseClaim(authData.token, "sign_in_second_factor") === ADMIN_TOTP_FACTOR
	);
}

export function requireAdminAccess(
	authData: AdminAuthData | null | undefined,
): AdminAuthData {
	if (!authData) {
		throw new HttpsError("unauthenticated", "Admin authentication is required");
	}
	if (!hasAdminAccess(authData)) {
		throw new HttpsError(
			"permission-denied",
			"This operation is restricted to the Better Keep administrator",
		);
	}
	return authData;
}

export function requireRecentAdminAccess(
	authData: AdminAuthData | null | undefined,
	nowSeconds = Math.floor(Date.now() / 1000),
): AdminAuthData {
	const admin = requireAdminAccess(authData);
	const authTime = admin.token.auth_time;
	if (
		typeof authTime !== "number" ||
		!Number.isFinite(authTime) ||
		authTime > nowSeconds ||
		nowSeconds - authTime > ADMIN_RECENT_AUTH_SECONDS
	) {
		throw new HttpsError(
			"failed-precondition",
			"Recent administrator authentication is required",
		);
	}
	return admin;
}

export function mergeAdminClaim(
	existingClaims: Record<string, unknown> | undefined,
): Record<string, unknown> {
	return {
		...(existingClaims ?? {}),
		[ADMIN_ACCESS_CLAIM]: true,
	};
}

export function removeAdminClaim(
	existingClaims: Record<string, unknown> | undefined,
): Record<string, unknown> {
	const claims = { ...(existingClaims ?? {}) };
	delete claims[ADMIN_ACCESS_CLAIM];
	return claims;
}
