import { Timestamp } from "firebase-admin/firestore";
import type { AuthBlockingEvent } from "firebase-functions/v2/identity";
import type { AccountLinkSessionData } from "./accountLinkSession";
import { db } from "./config";
import { EPHEMERAL_DOCUMENT_RETENTION_MS } from "./oauthSession";

const NATIVE_LINK_PROVIDERS = new Set(["google.com", "apple.com"]);

export function newNativeProviderLink(event: AuthBlockingEvent): string | null {
	const provider =
		event.credential?.providerId ?? event.additionalUserInfo?.providerId;
	if (!provider || !NATIVE_LINK_PROVIDERS.has(provider)) return null;
	if (event.additionalUserInfo?.isNewUser === true) return null;
	if (event.data.providerData?.some((entry) => entry.providerId === provider)) {
		return null;
	}
	return provider;
}

export async function authorizeNativeAccountLink(
	event: AuthBlockingEvent,
	provider: string,
): Promise<void> {
	const userRef = db.collection("users").doc(event.data.uid);
	const pendingRef = userRef.collection("pendingProviderLinks").doc(provider);
	const nowMs = Date.now();

	await db.runTransaction(async (transaction) => {
		const pending = await transaction.get(pendingRef);
		const pendingData = pending.data();
		const sessionId = pendingData?.sessionId;
		if (
			!pending.exists ||
			typeof sessionId !== "string" ||
			pendingData?.uid !== event.data.uid ||
			pendingData?.provider !== provider ||
			!pendingData.authorizationExpiresAt ||
			pendingData.authorizationExpiresAt.toMillis() <= nowMs
		) {
			throw new Error("Missing native account-link authorization");
		}

		const sessionRef = db.collection("accountLinkSessions").doc(sessionId);
		const session = await transaction.get(sessionRef);
		const sessionData = session.data() as AccountLinkSessionData | undefined;
		const expiresAt =
			sessionData?.authorizationExpiresAt ?? sessionData?.expiresAt;
		if (
			!session.exists ||
			!sessionData ||
			sessionData.status !== "issued" ||
			sessionData.uid !== event.data.uid ||
			sessionData.provider !== provider ||
			!expiresAt ||
			expiresAt.toMillis() <= nowMs
		) {
			throw new Error("Invalid native account-link authorization");
		}

		const now = Timestamp.fromMillis(nowMs);
		transaction.update(sessionRef, {
			status: "native_authorized",
			authorizedAt: now,
			authEventId: event.eventId,
			deleteAfter: Timestamp.fromMillis(
				nowMs + EPHEMERAL_DOCUMENT_RETENTION_MS,
			),
		});
		transaction.delete(pendingRef);
	});
}
