import type {
	DocumentReference,
	Firestore,
	Timestamp,
	Transaction,
} from "firebase-admin/firestore";

export type AccountLinkSessionStatus =
	| "issued"
	| "native_authorized"
	| "confirmed"
	| "custom_confirmed"
	| "superseded";

export interface AccountLinkSessionData {
	uid?: unknown;
	provider?: unknown;
	status?: unknown;
	authorizationExpiresAt?: { toMillis(): number } | null;
	expiresAt?: { toMillis(): number } | null;
	consumedAt?: unknown;
}

interface AccountLinkSessionExpectation {
	provider: string;
	uid?: string;
	nowMs?: number;
}

export class InvalidAccountLinkSessionError extends Error {
	constructor() {
		super("Account-link authorization is invalid, expired, or already used");
		this.name = "InvalidAccountLinkSessionError";
	}
}

function authorizationExpiry(
	data: AccountLinkSessionData,
): { toMillis(): number } | null {
	return data.authorizationExpiresAt ?? data.expiresAt ?? null;
}

export function isValidAccountLinkSession(
	data: AccountLinkSessionData | null | undefined,
	expectation: AccountLinkSessionExpectation,
): data is AccountLinkSessionData & {
	uid: string;
	provider: string;
} {
	const expiry = data ? authorizationExpiry(data) : null;
	return (
		!!data &&
		data.status === "issued" &&
		!data.consumedAt &&
		typeof data.uid === "string" &&
		data.provider === expectation.provider &&
		(expectation.uid === undefined || data.uid === expectation.uid) &&
		!!expiry &&
		expiry.toMillis() > (expectation.nowMs ?? Date.now())
	);
}

/**
 * Consumes an issued session for a server-side custom OAuth link.
 */
export async function consumeAccountLinkSession({
	db,
	sessionRef,
	expectation,
	consumedAt,
	onConsume,
}: {
	db: Firestore;
	sessionRef: DocumentReference;
	expectation: AccountLinkSessionExpectation;
	consumedAt: Timestamp;
	onConsume?: (transaction: Transaction) => void;
}): Promise<void> {
	await db.runTransaction(async (transaction) => {
		const session = await transaction.get(sessionRef);
		if (
			!session.exists ||
			!isValidAccountLinkSession(session.data(), expectation)
		) {
			throw new InvalidAccountLinkSessionError();
		}
		transaction.update(sessionRef, {
			status: "custom_confirmed",
			consumedAt,
			confirmedAt: consumedAt,
		});
		onConsume?.(transaction);
	});
}
