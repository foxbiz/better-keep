import { Timestamp, type Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { auth, db } from "./config";
import {
	challengeForVerifier,
	createOpaqueToken,
	EPHEMERAL_DOCUMENT_RETENTION_MS,
	hashOpaqueToken,
	isClientTransactionId,
	isOpaqueToken,
	OAUTH_COMPLETION_TTL_MS,
	OAUTH_REDEMPTION_LEASE_MS,
	timingSafeStringEqual,
	type CustomOAuthProvider,
} from "./oauthSession";

interface CompletionData {
	uid?: unknown;
	provider?: unknown;
	challenge?: unknown;
	clientTransactionId?: unknown;
	status?: unknown;
	expiresAt?: { toMillis(): number };
	leaseExpiresAt?: { toMillis(): number } | null;
	attemptId?: unknown;
}

export async function createOAuthCompletion({
	uid,
	provider,
	challenge,
	clientTransactionId,
}: {
	uid: string;
	provider: CustomOAuthProvider;
	challenge: string;
	clientTransactionId: string;
}): Promise<string> {
	if (
		!isOpaqueToken(challenge) ||
		!isClientTransactionId(clientTransactionId)
	) {
		throw new Error("Invalid OAuth completion parameters");
	}

	const code = createOpaqueToken();
	const nowMs = Date.now();
	await db
		.collection("oauthCompletions")
		.doc(hashOpaqueToken(code))
		.create({
			uid,
			provider,
			challenge,
			clientTransactionId,
			status: "pending",
			attemptId: null,
			leaseExpiresAt: null,
			createdAt: Timestamp.fromMillis(nowMs),
			expiresAt: Timestamp.fromMillis(nowMs + OAUTH_COMPLETION_TTL_MS),
			deleteAfter: Timestamp.fromMillis(
				nowMs + EPHEMERAL_DOCUMENT_RETENTION_MS,
			),
		});
	return code;
}

export async function redeemOAuthCompletion({
	code,
	verifier,
}: {
	code: string;
	verifier: string;
}): Promise<string> {
	return redeemOAuthCompletionWithDependencies({
		code,
		verifier,
		firestore: db,
		createCustomToken: (uid) => auth.createCustomToken(uid),
	});
}

export async function redeemOAuthCompletionWithDependencies({
	code,
	verifier,
	firestore,
	createCustomToken,
	now = () => Date.now(),
}: {
	code: string;
	verifier: string;
	firestore: Firestore;
	createCustomToken(uid: string): Promise<string>;
	now?: () => number;
}): Promise<string> {
	if (!isOpaqueToken(code) || !isOpaqueToken(verifier)) {
		throw new HttpsError("invalid-argument", "Invalid OAuth completion");
	}

	const completionRef = firestore
		.collection("oauthCompletions")
		.doc(hashOpaqueToken(code));
	const attemptId = createOpaqueToken();
	const nowMs = now();

	const uid = await firestore.runTransaction(async (transaction) => {
		const snapshot = await transaction.get(completionRef);
		const data = snapshot.data() as CompletionData | undefined;
		if (
			!snapshot.exists ||
			!data ||
			typeof data.uid !== "string" ||
			typeof data.challenge !== "string" ||
			!data.expiresAt ||
			data.expiresAt.toMillis() <= nowMs ||
			!timingSafeStringEqual(data.challenge, challengeForVerifier(verifier))
		) {
			throw new HttpsError(
				"permission-denied",
				"OAuth completion is invalid or expired",
			);
		}

		if (data.status !== "pending") {
			throw new HttpsError(
				"aborted",
				"OAuth completion is already being redeemed",
			);
		}

		transaction.update(completionRef, {
			status: "redeeming",
			attemptId,
			leaseExpiresAt: Timestamp.fromMillis(nowMs + OAUTH_REDEMPTION_LEASE_MS),
		});
		return data.uid;
	});

	let customToken: string;
	try {
		customToken = await createCustomToken(uid);
	} catch (error) {
		await firestore
			.runTransaction(async (transaction) => {
				const snapshot = await transaction.get(completionRef);
				if (snapshot.data()?.attemptId === attemptId) {
					transaction.update(completionRef, {
						status: "pending",
						attemptId: null,
						leaseExpiresAt: null,
					});
				}
			})
			.catch(() => undefined);
		if (error instanceof HttpsError) throw error;
		throw new HttpsError("internal", "Unable to complete OAuth sign-in");
	}

	try {
		await firestore.runTransaction(async (transaction) => {
			const snapshot = await transaction.get(completionRef);
			if (snapshot.data()?.attemptId !== attemptId) {
				throw new Error("OAuth completion lease was lost");
			}
			transaction.delete(completionRef);
		});
	} catch {
		// A token may already have been minted, so ambiguity must fail closed.
		// The record remains `redeeming` and cannot be reclaimed or replayed.
		throw new HttpsError("internal", "Unable to finalize OAuth sign-in");
	}
	return customToken;
}
