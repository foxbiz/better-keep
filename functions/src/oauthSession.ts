import * as crypto from "node:crypto";
import { CompactEncrypt, compactDecrypt } from "jose";
import type { AccountLinkProvider } from "./accountLinkProviders";

export const ACCOUNT_LINK_SESSION_TTL_MS = 10 * 60 * 1000;
export const OAUTH_STATE_TTL_MS = 5 * 60 * 1000;
export const OAUTH_COMPLETION_TTL_MS = 2 * 60 * 1000;
export const OAUTH_REDEMPTION_LEASE_MS = 30 * 1000;
export const EPHEMERAL_DOCUMENT_RETENTION_MS = 24 * 60 * 60 * 1000;
export const OAUTH_BROWSER_COOKIE = "__Host-bk-oauth";
export const OAUTH_STATE_AUDIENCE = "betterkeep-oauth-callback";

const CUSTOM_OAUTH_PROVIDERS = ["facebook", "github", "twitter"] as const;
export type CustomOAuthProvider = (typeof CUSTOM_OAUTH_PROVIDERS)[number];

export type OAuthRedirect = "popup" | "betterkeep";
export type OAuthMode = "signin" | "link";
export type OAuthFlowVersion = 1 | 2;

export interface OAuthState {
	version: OAuthFlowVersion;
	audience: typeof OAUTH_STATE_AUDIENCE;
	provider: CustomOAuthProvider;
	redirect: OAuthRedirect;
	mode: OAuthMode;
	linkingUserId?: string;
	linkSessionId?: string;
	codeVerifier?: string;
	clientOrigin?: string;
	clientTransactionId?: string;
	completionChallenge?: string;
	browserNonce: string;
	issuedAt: number;
	expiresAt: number;
}

const PRODUCTION_WEB_ORIGINS = new Set([
	"https://betterkeep.app",
	"https://better-keep-notes.web.app",
	"https://better-keep-notes.firebaseapp.com",
]);
const EMULATOR_WEB_ORIGINS = new Set([
	"http://localhost:63630",
	"http://127.0.0.1:63630",
]);

export function isCustomOAuthProvider(
	value: unknown,
): value is CustomOAuthProvider {
	return (
		typeof value === "string" &&
		CUSTOM_OAUTH_PROVIDERS.includes(value as CustomOAuthProvider)
	);
}

export function accountProviderFor(
	provider: CustomOAuthProvider,
): AccountLinkProvider {
	return `${provider}.com` as AccountLinkProvider;
}

export function parseOAuthRedirect(value: unknown): OAuthRedirect | null {
	if (value === undefined || value === null || value === "")
		return "betterkeep";
	return value === "popup" || value === "betterkeep" ? value : null;
}

export function parseOAuthMode(value: unknown): OAuthMode | null {
	if (value === undefined || value === null || value === "") return "signin";
	return value === "signin" || value === "link" ? value : null;
}

export function createOpaqueToken(): string {
	return crypto.randomBytes(32).toString("base64url");
}

export function createClientTransactionId(): string {
	return crypto.randomBytes(16).toString("base64url");
}

export function isOpaqueToken(value: unknown): value is string {
	return typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value);
}

export function isClientTransactionId(value: unknown): value is string {
	return typeof value === "string" && /^[A-Za-z0-9_-]{22}$/.test(value);
}

export function hashOpaqueToken(token: string): string {
	return crypto.createHash("sha256").update(token).digest("hex");
}

export function challengeForVerifier(verifier: string): string {
	return crypto.createHash("sha256").update(verifier).digest("base64url");
}

export function timingSafeStringEqual(left: string, right: string): boolean {
	const leftBuffer = Buffer.from(left);
	const rightBuffer = Buffer.from(right);
	return (
		leftBuffer.length === rightBuffer.length &&
		crypto.timingSafeEqual(leftBuffer, rightBuffer)
	);
}

export function isAllowedOAuthClientOrigin(
	value: unknown,
	isEmulator: boolean,
): value is string {
	if (typeof value !== "string") return false;
	return (
		PRODUCTION_WEB_ORIGINS.has(value) ||
		(isEmulator && EMULATOR_WEB_ORIGINS.has(value))
	);
}

export function originFromReferrer(
	referrer: string | undefined,
	isEmulator: boolean,
): string | null {
	if (!referrer) return null;
	try {
		const origin = new URL(referrer).origin;
		return isAllowedOAuthClientOrigin(origin, isEmulator) ? origin : null;
	} catch {
		return null;
	}
}

function oauthStateKey(secret: string): Uint8Array {
	const trimmed = secret.trim();
	const candidates = [
		() => Buffer.from(trimmed, "base64url"),
		() => Buffer.from(trimmed, "base64"),
	];
	for (const decode of candidates) {
		const key = decode();
		if (key.length === 32) return key;
	}
	throw new Error("OAUTH_STATE_SECRET must encode exactly 32 bytes");
}

export async function sealOAuthState(
	state: OAuthState,
	secret: string,
): Promise<string> {
	return new CompactEncrypt(Buffer.from(JSON.stringify(state)))
		.setProtectedHeader({
			alg: "dir",
			enc: "A256GCM",
			typ: "betterkeep-oauth-state",
		})
		.encrypt(oauthStateKey(secret));
}

export async function openOAuthState(
	compactJwe: string,
	secret: string,
	nowMs = Date.now(),
): Promise<OAuthState> {
	const { plaintext, protectedHeader } = await compactDecrypt(
		compactJwe,
		oauthStateKey(secret),
	);
	if (
		protectedHeader.alg !== "dir" ||
		protectedHeader.enc !== "A256GCM" ||
		protectedHeader.typ !== "betterkeep-oauth-state"
	) {
		throw new Error("Invalid OAuth state header");
	}

	const value = JSON.parse(
		Buffer.from(plaintext).toString("utf8"),
	) as Partial<OAuthState>;
	if (
		(value.version !== 1 && value.version !== 2) ||
		value.audience !== OAUTH_STATE_AUDIENCE ||
		!isCustomOAuthProvider(value.provider) ||
		(value.redirect !== "popup" && value.redirect !== "betterkeep") ||
		(value.mode !== "signin" && value.mode !== "link") ||
		!isOpaqueToken(value.browserNonce) ||
		typeof value.issuedAt !== "number" ||
		typeof value.expiresAt !== "number" ||
		value.issuedAt > nowMs + 30_000 ||
		value.expiresAt <= nowMs ||
		value.expiresAt - value.issuedAt > OAUTH_STATE_TTL_MS
	) {
		throw new Error("Invalid or expired OAuth state");
	}
	if (value.redirect === "popup" && typeof value.clientOrigin !== "string") {
		throw new Error("Missing OAuth client origin");
	}
	if (
		value.mode === "link" &&
		(typeof value.linkingUserId !== "string" ||
			typeof value.linkSessionId !== "string")
	) {
		throw new Error("Invalid account-link OAuth state");
	}
	if (
		value.version === 2 &&
		(!isClientTransactionId(value.clientTransactionId) ||
			!isOpaqueToken(value.completionChallenge))
	) {
		throw new Error("Invalid OAuth completion challenge");
	}
	return value as OAuthState;
}

export function oauthCookieHeader(
	browserNonce: string,
	maxAgeSeconds = Math.floor(OAUTH_STATE_TTL_MS / 1000),
): string {
	return `${OAUTH_BROWSER_COOKIE}=${browserNonce}; Max-Age=${maxAgeSeconds}; Path=/; Secure; HttpOnly; SameSite=Lax`;
}

export function clearOAuthCookieHeader(): string {
	return `${OAUTH_BROWSER_COOKIE}=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax`;
}

export function readOAuthBrowserNonce(
	cookieHeader: string | undefined,
): string | null {
	if (!cookieHeader) return null;
	for (const part of cookieHeader.split(";")) {
		const [rawName, ...rawValue] = part.trim().split("=");
		if (rawName === OAUTH_BROWSER_COOKIE) {
			const value = rawValue.join("=");
			return isOpaqueToken(value) ? value : null;
		}
	}
	return null;
}
