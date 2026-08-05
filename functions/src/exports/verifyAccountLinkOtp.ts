import * as crypto from "node:crypto";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import type { CallableRequest } from "firebase-functions/v2/https";
import { HttpsError } from "firebase-functions/v2/https";
import { isAccountLinkProvider } from "../accountLinkProviders";
import { db } from "../config";
import { onNonReviewCall } from "../nonReviewCallable";
import {
	ACCOUNT_LINK_SESSION_TTL_MS,
	createOpaqueToken,
	EPHEMERAL_DOCUMENT_RETENTION_MS,
	hashOpaqueToken,
} from "../oauthSession";

/**
 * HTTP Callable function to verify OTP for account linking
 * Returns a one-time link authorization that must be used within 10 minutes.
 */
export default onNonReviewCall(
	async (request: CallableRequest<{ otp: string; provider: string }>) => {
		if (!request.auth) {
			throw new HttpsError(
				"unauthenticated",
				"User must be signed in to verify OTP",
			);
		}
		const userId = request.auth.uid;
		const providedOtp = request.data?.otp;
		const provider = request.data?.provider;

		if (!providedOtp || typeof providedOtp !== "string") {
			throw new HttpsError("invalid-argument", "Verification code is required");
		}

		if (!isAccountLinkProvider(provider)) {
			throw new HttpsError("invalid-argument", "Invalid provider");
		}

		try {
			const userRef = db.collection("users").doc(userId);
			const otpRef = userRef.collection("otpVerification").doc("accountLink");
			const now = Timestamp.now();
			const providedOtpHash = crypto
				.createHash("sha256")
				.update(providedOtp)
				.digest("hex");
			const linkToken = createOpaqueToken();
			const linkTokenHash = hashOpaqueToken(linkToken);
			const linkTokenExpires = Timestamp.fromMillis(
				Date.now() + ACCOUNT_LINK_SESSION_TTL_MS,
			);
			const linkSessionRef = db
				.collection("accountLinkSessions")
				.doc(linkTokenHash);
			const isNativeProvider =
				provider === "google.com" || provider === "apple.com";
			const pendingLinkRef = userRef
				.collection("pendingProviderLinks")
				.doc(provider);
			const deleteAfter = Timestamp.fromMillis(
				Date.now() + EPHEMERAL_DOCUMENT_RETENTION_MS,
			);

			const outcome = await db.runTransaction(async (transaction) => {
				const otpDoc = await transaction.get(otpRef);
				const existingPending = isNativeProvider
					? await transaction.get(pendingLinkRef)
					: null;
				const otpData = otpDoc.data();
				if (!otpDoc.exists || !otpData) {
					return {
						code: "not-found" as const,
						message: "No verification code found. Please request a new one.",
					};
				}
				if (otpData.verified || otpData.linkTokenHash) {
					return {
						code: "failed-precondition" as const,
						message:
							"This verification code was already used. Please request a new one.",
					};
				}
				if (
					!otpData.expiresAt ||
					typeof otpData.expiresAt.toMillis !== "function"
				) {
					transaction.delete(otpRef);
					return {
						code: "failed-precondition" as const,
						message: "Invalid verification state. Please request a new code.",
					};
				}
				if (otpData.expiresAt.toMillis() < now.toMillis()) {
					transaction.delete(otpRef);
					return {
						code: "deadline-exceeded" as const,
						message: "Verification code has expired. Please request a new one.",
					};
				}
				if (otpData.provider !== provider) {
					return {
						code: "invalid-argument" as const,
						message:
							"Provider mismatch. Please request a new code for this provider.",
					};
				}

				const attempts =
					typeof otpData.attempts === "number" ? otpData.attempts : 0;
				if (attempts >= 5) {
					transaction.delete(otpRef);
					return {
						code: "resource-exhausted" as const,
						message: "Too many attempts. Please request a new code.",
					};
				}
				if (otpData.otpHash !== providedOtpHash) {
					transaction.update(otpRef, {
						attempts: FieldValue.increment(1),
					});
					const remainingAttempts = 4 - attempts;
					return {
						code: "permission-denied" as const,
						message: `Invalid code. ${remainingAttempts} attempt${
							remainingAttempts !== 1 ? "s" : ""
						} remaining.`,
					};
				}

				transaction.set(
					otpRef,
					{
						verified: true,
						verifiedAt: now,
						linkTokenHash,
						linkTokenExpires,
						provider,
					},
					{ merge: true },
				);
				transaction.set(linkSessionRef, {
					uid: userId,
					provider,
					status: "issued",
					createdAt: now,
					authorizationExpiresAt: linkTokenExpires,
					expiresAt: linkTokenExpires,
					deleteAfter,
					consumedAt: null,
				});
				const previousSessionId = existingPending?.data()?.sessionId;
				if (
					typeof previousSessionId === "string" &&
					previousSessionId !== linkTokenHash
				) {
					transaction.set(
						db.collection("accountLinkSessions").doc(previousSessionId),
						{
							status: "superseded",
							supersededAt: now,
							deleteAfter,
						},
						{ merge: true },
					);
				}
				if (isNativeProvider) {
					transaction.set(pendingLinkRef, {
						uid: userId,
						provider,
						sessionId: linkTokenHash,
						createdAt: now,
						authorizationExpiresAt: linkTokenExpires,
						deleteAfter,
					});
				}
				return null;
			});
			if (outcome) {
				throw new HttpsError(outcome.code, outcome.message);
			}

			console.info(
				JSON.stringify({
					event: "account_link_authorization_issued",
					provider,
				}),
			);

			return {
				success: true,
				message: "Verification successful. Complete the linking now.",
				linkToken: linkToken,
				provider: provider,
				tokenExpiresIn: 600,
			};
		} catch (error) {
			console.error("Account-link OTP verification failed", {
				provider,
				code: error instanceof HttpsError ? error.code : "internal",
			});

			if (error instanceof HttpsError) {
				throw error;
			}

			throw new HttpsError("internal", "Failed to verify code");
		}
	},
);
