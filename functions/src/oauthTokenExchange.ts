/** Provider-neutral transport. Configuration is trusted server code, never input. */
export interface OAuthExchangeProvider {
	clientId: string;
	clientSecret: string;
	tokenEndpoint: string;
	redirectUris: readonly string[];
}
export type OAuthTokenInput =
	| {
			operation: "code";
			clientId: string;
			code: string;
			verifier: string;
			redirectUri: string;
	  }
	| { operation: "refresh"; clientId: string; refreshToken: string };
export class OAuthExchangeError extends Error {
	constructor(
		readonly kind: "invalid" | "reconnect_required" | "unavailable" | "busy",
	) {
		super(`OAuth exchange ${kind}`);
	}
}
function secret(value: unknown): value is string {
	return (
		typeof value === "string" &&
		value.length > 0 &&
		value.length <= 16384 &&
		![...value].some(
			(char) => char.charCodeAt(0) <= 32 || char.charCodeAt(0) === 127,
		)
	);
}
export function parseOAuthTokenInput(
	data: Record<string, unknown>,
): OAuthTokenInput {
	if (!secret(data.clientId)) throw new OAuthExchangeError("invalid");
	if (
		data.operation === "code" &&
		secret(data.code) &&
		typeof data.verifier === "string" &&
		/^[A-Za-z0-9._~-]{43,128}$/.test(data.verifier) &&
		typeof data.redirectUri === "string"
	) {
		return {
			operation: "code",
			clientId: data.clientId,
			code: data.code,
			verifier: data.verifier,
			redirectUri: data.redirectUri,
		};
	}
	if (data.operation === "refresh" && secret(data.refreshToken))
		return {
			operation: "refresh",
			clientId: data.clientId,
			refreshToken: data.refreshToken,
		};
	throw new OAuthExchangeError("invalid");
}

/** Tokens live only in this request. No persistence, request/body logging or retries. */
export async function exchangeOAuthToken(
	provider: OAuthExchangeProvider,
	input: OAuthTokenInput,
	request: typeof fetch = fetch,
	now = Date.now,
) {
	try {
		const endpoint = new URL(provider.tokenEndpoint);
		if (
			endpoint.protocol !== "https:" ||
			endpoint.username ||
			endpoint.password ||
			endpoint.hash ||
			endpoint.search ||
			!provider.clientSecret ||
			input.clientId !== provider.clientId ||
			(input.operation === "code" &&
				!provider.redirectUris.includes(input.redirectUri))
		)
			throw new OAuthExchangeError("invalid");
		const form = new URLSearchParams({
			client_id: provider.clientId,
			client_secret: provider.clientSecret,
		});
		if (input.operation === "code") {
			form.set("grant_type", "authorization_code");
			form.set("code", input.code);
			form.set("code_verifier", input.verifier);
			form.set("redirect_uri", input.redirectUri);
		} else {
			form.set("grant_type", "refresh_token");
			form.set("refresh_token", input.refreshToken);
		}
		const response = await request(endpoint, {
			method: "POST",
			headers: { "Content-Type": "application/x-www-form-urlencoded" },
			body: form,
			redirect: "error",
			signal: AbortSignal.timeout(15000),
		});
		if (!response.ok) {
			await response.body?.cancel();
			throw new OAuthExchangeError(
				response.status === 400 || response.status === 401
					? "reconnect_required"
					: response.status === 429
						? "busy"
						: "unavailable",
			);
		}
		const reader = response.body?.getReader();
		if (!reader) throw new OAuthExchangeError("unavailable");
		const chunks: Uint8Array[] = [];
		let size = 0;
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			size += value.length;
			if (size > 65536) {
				await reader.cancel();
				throw new OAuthExchangeError("unavailable");
			}
			chunks.push(value);
		}
		const data = JSON.parse(Buffer.concat(chunks).toString("utf8"));
		if (
			!data ||
			!secret(data.access_token) ||
			typeof data.expires_in !== "number" ||
			!Number.isFinite(data.expires_in) ||
			data.expires_in <= 0 ||
			data.expires_in > 86400 ||
			typeof data.token_type !== "string" ||
			data.token_type.toLowerCase() !== "bearer" ||
			(data.refresh_token !== undefined && !secret(data.refresh_token)) ||
			(input.operation === "code" && !secret(data.refresh_token))
		)
			throw new OAuthExchangeError("reconnect_required");
		return {
			type: "oauth",
			accessToken: data.access_token as string,
			expiresAt: now() + Math.floor(data.expires_in * 1000),
			...(data.refresh_token
				? { refreshToken: data.refresh_token as string }
				: {}),
		};
	} catch (error) {
		if (error instanceof OAuthExchangeError) throw error;
		throw new OAuthExchangeError("unavailable");
	}
}
