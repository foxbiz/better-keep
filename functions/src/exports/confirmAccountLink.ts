import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { isAccountLinkProvider } from "../accountLinkProviders";
import { auth, db } from "../config";
import {
	type AuthenticatedCallableRequest,
	onNonReviewCall,
} from "../nonReviewCallable";
import {
	EPHEMERAL_DOCUMENT_RETENTION_MS,
	hashOpaqueToken,
	isOpaqueToken,
} from "../oauthSession";

/**
 * Consumes the OTP-issued link session after a native Firebase provider link.
 */
export default onNonReviewCall(
	async (
		request: AuthenticatedCallableRequest<{
			linkToken: string;
			provider: string;
		}>,
	) => {
		const caller = request.auth;
		const linkToken = request.data?.linkToken;
		const provider = request.data?.provider;

		if (!isOpaqueToken(linkToken)) {
			throw new HttpsError("invalid-argument", "Link token is required");
		}
		if (!isAccountLinkProvider(provider)) {
			throw new HttpsError("invalid-argument", "Invalid provider");
		}

		const sessionRef = db
			.collection("accountLinkSessions")
			.doc(hashOpaqueToken(linkToken));
		const userRef = db.collection("users").doc(caller.uid);
		const otpRef = userRef.collection("otpVerification").doc("accountLink");
		const auditRef = userRef
			.collection("auditLog")
			.doc(`account-link-${sessionRef.id}`);
		const pendingRef = userRef.collection("pendingProviderLinks").doc(provider);
		const now = Timestamp.now();

		try {
			const existingSession = await sessionRef.get();
			const existingData = existingSession.data();
			if (
				!existingSession.exists ||
				existingData?.uid !== caller.uid ||
				existingData?.provider !== provider
			) {
				throw new HttpsError(
					"permission-denied",
					"Account-link authorization is invalid",
				);
			}
			if (existingData.status === "confirmed") {
				return {
					success: true,
					message: "Account linked successfully!",
				};
			}
			if (existingData.status !== "native_authorized") {
				throw new HttpsError(
					"permission-denied",
					"Account-link authorization was not used by Firebase Authentication",
				);
			}

			const userRecord = await auth.getUser(caller.uid);
			if (
				!userRecord.providerData.some(
					(entry) => entry.providerId === provider,
				)
			) {
				throw new HttpsError(
					"failed-precondition",
					"The provider has not been linked in Firebase Authentication",
				);
			}

			await db.runTransaction(async (transaction) => {
				const session = await transaction.get(sessionRef);
				const data = session.data();
				if (
					!session.exists ||
					data?.uid !== caller.uid ||
					data?.provider !== provider
				) {
					throw new HttpsError(
						"permission-denied",
						"Account-link authorization is invalid",
					);
				}
				if (data.status === "confirmed") return;
				if (data.status !== "native_authorized") {
					throw new HttpsError(
						"permission-denied",
						"Account-link authorization was not used by Firebase Authentication",
					);
				}

				transaction.set(
					userRef,
					{
						linkedProviders: {
							[provider.replace(".com", "")]: {
								linkedAt: now,
								linkedVia: "native_oauth_link",
							},
						},
					},
					{ merge: true },
				);
				transaction.set(auditRef, {
					action: "account_linked",
					provider,
					timestamp: now,
					success: true,
					sessionId: sessionRef.id,
				});
				transaction.update(sessionRef, {
					status: "confirmed",
					confirmedAt: now,
					consumedAt: now,
					deleteAfter: Timestamp.fromMillis(
						now.toMillis() + EPHEMERAL_DOCUMENT_RETENTION_MS,
					),
				});
				transaction.delete(otpRef);
				transaction.delete(pendingRef);
			});
		} catch (error) {
			if (error instanceof HttpsError) throw error;
			console.error("Account-link confirmation failed", {
				provider,
				error: error instanceof Error ? error.message : "unknown",
			});
			throw new HttpsError("internal", "Failed to confirm account link");
		}

		return {
			success: true,
			message: "Account linked successfully!",
		};
	},
);
