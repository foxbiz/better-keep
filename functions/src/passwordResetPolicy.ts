import { isReviewAccountEmail } from "./reviewAccess";

/**
 * Password resets for the managed review email are operator-only.
 *
 * The unauthenticated request route uses this to return its normal generic
 * success response without creating an OTP. Verification and reset routes use
 * the same policy to reject attempts even if a stale OTP document exists.
 */
export function isOperatorManagedPasswordReset(email: unknown): boolean {
	return isReviewAccountEmail(email);
}
