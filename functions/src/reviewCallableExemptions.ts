/**
 * Every callable that intentionally bypasses onNonReviewCall must be listed
 * here with a security reason. The source contract test rejects new raw
 * onCall exports unless they are explicitly reviewed.
 */
export const REVIEW_CALLABLE_EXEMPTIONS: Readonly<Record<string, string>> = {
	redeemOAuthCompletion:
		"Unauthenticated sign-in completion protected by an expiring code and verifier",
	resetPasswordWithOtp:
		"Unauthenticated account recovery with managed-review password policy",
	sendPasswordResetOtp:
		"Public recovery entry point with email-specific throttling and review policy",
	setEmulatorTestClaims:
		"Emulator-only test helper that rejects non-emulator execution",
	verifyPasswordResetOtp:
		"Unauthenticated recovery step that does not grant an authenticated session",
};
