import { HttpsError } from "firebase-functions/v2/https";
import { db, googleDriveClientSecret, isEmulator } from "./config";
import { onNonReviewCall } from "./nonReviewCallable";
import {
	exchangeOAuthToken,
	OAuthExchangeError,
	type OAuthExchangeProvider,
	parseOAuthTokenInput,
} from "./oauthTokenExchange";
import {
	beginStorageTokenRefresh,
	completeStorageTokenRefresh,
	requireStorageSession,
	sanitizedStorageAction,
	storageTokenExchangeGeneration,
} from "./storageConnectionBackend";
import { StorageConnectionError } from "./storageConnectionSecurity";
import { signStorageGrant, storageRefreshBinding } from "./storageTokenBinding";

// Adding a provider requires an explicit server-owned registration. Never accept
// caller-controlled token endpoints, secrets, scopes, or arbitrary form fields.
function googleDriveConfiguration(): OAuthExchangeProvider {
	const clientId = process.env.GOOGLE_DRIVE_CLIENT_ID?.trim();
	const origin = new URL(
		isEmulator
			? process.env.EMULATOR_WEB_ORIGIN || "invalid:"
			: "https://betterkeep.app",
	);
	if (
		!clientId ||
		origin.protocol !== "https:" ||
		!origin.hostname ||
		origin.username ||
		origin.password ||
		origin.search ||
		origin.hash ||
		origin.pathname !== "/"
	)
		throw new HttpsError(
			"failed-precondition",
			"Storage OAuth is not configured",
		);
	return {
		clientId,
		clientSecret: googleDriveClientSecret.value(),
		tokenEndpoint: "https://oauth2.googleapis.com/token",
		redirectUris: [new URL("/oauth/storage/callback", origin).href],
	};
}
const providerRegistry = new Map<string, () => OAuthExchangeProvider>([
	["google_drive", googleDriveConfiguration],
]);
function providerConfiguration(provider: unknown): OAuthExchangeProvider {
	const configure =
		typeof provider === "string" ? providerRegistry.get(provider) : undefined;
	if (!configure) throw new OAuthExchangeError("invalid");
	return configure();
}

async function safe<T>(action: () => Promise<T>) {
	return sanitizedStorageAction(async () => {
		try {
			return await action();
		} catch (error) {
			if (error instanceof OAuthExchangeError)
				throw new StorageConnectionError(error.kind);
			throw error;
		}
	});
}
// Only counters/timestamps are stored. Limits apply across function instances.
async function consumeBudget(uid: string) {
	const ref = db.collection("oauth_exchange_limits").doc(uid);
	await db.runTransaction(async (tx) => {
		const data = (await tx.get(ref)).data();
		const now = Date.now();
		const sameWindow =
			typeof data?.startedAt === "number" && now - data.startedAt < 60000;
		const count = sameWindow ? (data?.count ?? 0) : 0;
		if (count >= 20)
			throw new HttpsError("resource-exhausted", "Try again shortly");
		tx.set(ref, {
			startedAt: sameWindow ? data?.startedAt : now,
			count: count + 1,
		});
	});
}
export const prepareStorageTokenExchange = onNonReviewCall<
	Record<string, unknown>
>({ secrets: [googleDriveClientSecret] }, (request) =>
	safe(async () => {
		await requireStorageSession(request);
		const config = providerConfiguration(request.data.provider);
		if (!config.clientSecret)
			throw new HttpsError(
				"failed-precondition",
				"Storage OAuth is not configured",
			);
		return { clientId: config.clientId, redirectUri: config.redirectUris[0] };
	}),
);
export const exchangeStorageOAuthToken = onNonReviewCall<
	Record<string, unknown>
>(
	{ secrets: [googleDriveClientSecret], timeoutSeconds: 30, maxInstances: 10 },
	(request) =>
		safe(async () => {
			const data = request.data;
			const allowed = new Set([
				"provider",
				"deviceId",
				"operation",
				"clientId",
				"code",
				"verifier",
				"redirectUri",
				"refreshToken",
				"capability",
				"generation",
				"revision",
				"leaseId",
				"fence",
			]);
			if (!data || Object.keys(data).some((key) => !allowed.has(key)))
				throw new OAuthExchangeError("invalid");
			const input = parseOAuthTokenInput(data);
			const context = await requireStorageSession(request);
			const config = providerConfiguration(data.provider);
			if (
				input.clientId !== config.clientId ||
				(input.operation === "code" &&
					!config.redirectUris.includes(input.redirectUri))
			)
				throw new OAuthExchangeError("invalid");
			const binding = (generation: number, token: string) =>
				storageRefreshBinding(
					config.clientSecret,
					context,
					input.clientId,
					generation,
					token,
				);
			if (input.operation === "code") {
				const generation = await storageTokenExchangeGeneration(context);
				await consumeBudget(context.uid);
				const result = await exchangeOAuthToken(config, input);
				await requireStorageSession(request);
				if ((await storageTokenExchangeGeneration(context)) !== generation)
					throw new StorageConnectionError("denied");
				if (!result.refreshToken)
					throw new OAuthExchangeError("reconnect_required");
				return {
					...result,
					exchangeProof: signStorageGrant(
						config.clientSecret,
						context,
						input.clientId,
						generation,
						binding(generation, result.refreshToken),
					),
				};
			}
			if (
				typeof data.capability !== "string" ||
				typeof data.leaseId !== "string" ||
				![data.generation, data.revision, data.fence].every(
					(n) => typeof n === "number" && Number.isSafeInteger(n) && n > 0,
				)
			)
				throw new OAuthExchangeError("invalid");
			const lease = {
				generation: data.generation as number,
				revision: data.revision as number,
				fence: data.fence as number,
				leaseId: data.leaseId,
				clientId: input.clientId,
				binding: binding(data.generation as number, input.refreshToken),
			};
			const exchangeId = await beginStorageTokenRefresh(
				context,
				data.capability,
				lease,
			);
			await consumeBudget(context.uid);
			const result = await exchangeOAuthToken(config, input);
			await requireStorageSession(request);
			await completeStorageTokenRefresh(
				context,
				data.capability,
				lease,
				exchangeId,
				binding(lease.generation, result.refreshToken ?? input.refreshToken),
			);
			return result;
		}),
);
