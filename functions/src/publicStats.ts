export type PublicStatsPayload = {
	schemaVersion: 1;
	label: "users";
	message: string;
	color: "blue" | "red";
	metric?: string;
};

const exactAllowedOrigins = new Set([
	"https://betterkeep.app",
	"https://better-keep-notes.web.app",
	"https://better-keep-notes.firebaseapp.com",
]);

const localDevelopmentHosts = new Set(["localhost", "127.0.0.1", "[::1]"]);

const previewOriginPattern =
	/^https:\/\/better-keep-notes--[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.web\.app$/;
const compactMetricPattern = /^\d+(?:\.\d)?[KM]\+$/;
const roundedCountPattern = /^(\d+)(\+)?$/;

function isLocalDevelopmentOrigin(origin: string): boolean {
	try {
		const url = new URL(origin);
		return (
			url.origin === origin &&
			url.protocol === "http:" &&
			localDevelopmentHosts.has(url.hostname)
		);
	} catch {
		return false;
	}
}

export function isPublicStatsOriginAllowed(origin: string | undefined): boolean {
	if (!origin) return true;
	return (
		exactAllowedOrigins.has(origin) ||
		previewOriginPattern.test(origin) ||
		isLocalDevelopmentOrigin(origin)
	);
}

export function compactPublicUserCount(value: unknown): string | null {
	if (typeof value !== "string") return null;
	const normalized = value.trim().toUpperCase();
	if (compactMetricPattern.test(normalized)) return normalized;

	const match = normalized.match(roundedCountPattern);
	if (!match) return null;
	const count = Number.parseInt(match[1], 10);
	if (!Number.isSafeInteger(count) || count <= 0) return null;

	const plus = match[2] || "";
	if (count < 1000) return `${count}${plus}`;

	const divisor = count >= 1_000_000 ? 1_000_000 : 1000;
	const unit = divisor === 1_000_000 ? "M" : "K";
	const compact = Math.floor((count / divisor) * 10) / 10;
	const formatted = Number.isInteger(compact)
		? compact.toFixed(0)
		: compact.toFixed(1);
	return `${formatted}${unit}${plus}`;
}

export function createPublicStatsPayload(
	value: unknown,
	color: "blue" | "red" = "blue",
): PublicStatsPayload {
	const message = typeof value === "string" && value.trim() ? value.trim() : "0";
	const metric = compactPublicUserCount(message);
	return {
		schemaVersion: 1,
		label: "users",
		message,
		color,
		...(metric ? {metric} : {}),
	};
}
