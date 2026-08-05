import { HttpsError } from "firebase-functions/v2/https";
import { REVIEW_ACCESS_CLAIM, REVIEW_ACCOUNT_EMAIL } from "./reviewConfig";

export { REVIEW_ACCESS_CLAIM };

export interface ReviewAuthData {
	uid: string;
	token: Record<string, unknown>;
}

export interface ReviewUserRecordLike {
	email?: string | null;
	customClaims?: Record<string, unknown>;
}

export function isReviewAccountEmail(email: unknown): boolean {
	return (
		typeof email === "string" &&
		email.trim().toLowerCase() === REVIEW_ACCOUNT_EMAIL.toLowerCase()
	);
}

/** Returns true only for the Firebase-signed review identity and claim. */
export function hasReviewAccess(
	authData: ReviewAuthData | null | undefined,
): authData is ReviewAuthData {
	if (!authData) return false;

	const tokenEmail = authData.token.email;
	return (
		isReviewAccountEmail(tokenEmail) &&
		authData.token[REVIEW_ACCESS_CLAIM] === true
	);
}

/**
 * Returns true for any identity that must be protected as the review account.
 *
 * Positive review authorization intentionally requires both the configured
 * email and signed claim. Mutation protection is broader and fails closed when
 * either marker is present so a missing or accidentally copied claim cannot
 * turn the managed review identity into an ordinary mutable account.
 */
export function isProtectedReviewIdentity(
	authData: ReviewAuthData | null | undefined,
): authData is ReviewAuthData {
	if (!authData) return false;
	return (
		isReviewAccountEmail(authData.token.email) ||
		authData.token[REVIEW_ACCESS_CLAIM] === true
	);
}

/** Server-side variant for Firebase Auth user records and blocking events. */
export function isProtectedReviewUserRecord(
	user: ReviewUserRecordLike | null | undefined,
): boolean {
	return (
		!!user &&
		(isReviewAccountEmail(user.email) ||
			user.customClaims?.[REVIEW_ACCESS_CLAIM] === true)
	);
}

/** The managed review identity may authenticate only with email/password. */
export function isAllowedReviewSignIn(
	user: ReviewUserRecordLike | null | undefined,
	eventType: unknown,
): boolean {
	if (!isProtectedReviewUserRecord(user)) return true;
	return typeof eventType === "string" && eventType.endsWith(":password");
}

/** Requires the caller to be the authorized app-review account. */
export function requireReviewAccess(
	authData: ReviewAuthData | null | undefined,
): ReviewAuthData {
	if (!authData) {
		throw new HttpsError("unauthenticated", "Authentication is required");
	}
	if (!hasReviewAccess(authData)) {
		throw new HttpsError(
			"permission-denied",
			"This operation is restricted to the app-review account",
		);
	}
	return authData;
}

/** Requires an authenticated caller that is not the managed review identity. */
export function requireNonReviewAccess(
	authData: ReviewAuthData | null | undefined,
): ReviewAuthData {
	if (!authData) {
		throw new HttpsError("unauthenticated", "Authentication is required");
	}
	if (isProtectedReviewIdentity(authData)) {
		throw new HttpsError(
			"permission-denied",
			"This operation is unavailable for the managed review account",
		);
	}
	return authData;
}
