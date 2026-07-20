import { isDeepStrictEqual } from "node:util";

export type ReminderDocument = Record<string, unknown>;

export interface ReminderStateV3 {
	version: 3;
	source: "alarm" | "none";
	generation: string;
	base_generation: string | null;
	writer: "legacy_bridge";
	event_id: string;
}

export interface LegacyReminderTransition {
	baseState: unknown;
	baseGeneration: string | null;
	reminderV2: unknown;
}

export interface ReminderStateResolution {
	state: ReminderStateV3;
	deleteReminderV2: true;
}

function generationOf(state: unknown): string | null {
	if (typeof state !== "object" || state === null) return null;
	const generation = (state as Record<string, unknown>).generation;
	return typeof generation === "string" ? generation : null;
}

function isLegacyBridgeForBase(
	state: unknown,
	baseGeneration: string | null,
): boolean {
	if (typeof state !== "object" || state === null) return false;
	const value = state as Record<string, unknown>;
	return (
		value.version === 3 &&
		value.writer === "legacy_bridge" &&
		(value.base_generation ?? null) === baseGeneration
	);
}

export function detectLegacyReminderTransition(
	before: ReminderDocument,
	after: ReminderDocument,
): LegacyReminderTransition | null {
	if (isDeepStrictEqual(before.reminder, after.reminder)) return null;
	if (!isDeepStrictEqual(before.reminder_v2, after.reminder_v2)) return null;
	if (
		!isDeepStrictEqual(
			before.reminder_state_v3,
			after.reminder_state_v3,
		)
	) {
		return null;
	}
	return {
		baseState: after.reminder_state_v3,
		baseGeneration: generationOf(after.reminder_state_v3),
		reminderV2: after.reminder_v2,
	};
}

export function resolveLegacyReminderTransition(
	transition: LegacyReminderTransition,
	current: ReminderDocument,
	eventId: string,
): ReminderStateResolution | null {
	const stateMatchesBase = isDeepStrictEqual(
		current.reminder_state_v3,
		transition.baseState,
	);
	const stateContinuesBridge = isLegacyBridgeForBase(
		current.reminder_state_v3,
		transition.baseGeneration,
	);
	if (!stateMatchesBase && !stateContinuesBridge) return null;
	if (
		stateMatchesBase &&
		!isDeepStrictEqual(current.reminder_v2, transition.reminderV2)
	) {
		return null;
	}

	const source = current.reminder == null ? "none" : "alarm";
	const currentState = current.reminder_state_v3;
	if (
		current.reminder_v2 == null &&
		typeof currentState === "object" &&
		currentState !== null &&
		(currentState as Record<string, unknown>).source === source
	) {
		return null;
	}

	return {
		deleteReminderV2: true,
		state: {
			version: 3,
			source,
			generation: `legacy:${eventId}`,
			base_generation: transition.baseGeneration,
			writer: "legacy_bridge",
			event_id: eventId,
		},
	};
}
