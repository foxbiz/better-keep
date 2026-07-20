const assert = require("node:assert/strict");
const test = require("node:test");
const {
	detectLegacyReminderTransition,
	resolveLegacyReminderTransition,
} = require("../lib/reminderStateResolver");

const notification = { version: 2, data: { type: "notification" } };
const baseState = {
	version: 3,
	source: "notification",
	generation: "client-a:1",
};

test("detects only legacy-only reminder changes", () => {
	const transition = detectLegacyReminderTransition(
		{ reminder: null, reminder_v2: notification, reminder_state_v3: baseState },
		{ reminder: "alarm", reminder_v2: notification, reminder_state_v3: baseState },
	);
	assert.ok(transition);
	assert.equal(transition.baseGeneration, "client-a:1");

	assert.equal(
		detectLegacyReminderTransition(
			{ reminder: null, reminder_v2: notification, reminder_state_v3: baseState },
			{
				reminder: null,
				reminder_v2: { version: 2, data: { revision: 2 } },
				reminder_state_v3: { ...baseState, generation: "client-b:2" },
			},
		),
		null,
	);
});

test("legacy alarm clears v2 and becomes authoritative", () => {
	const transition = detectLegacyReminderTransition(
		{ reminder: null, reminder_v2: notification, reminder_state_v3: baseState },
		{ reminder: "alarm", reminder_v2: notification, reminder_state_v3: baseState },
	);
	assert.ok(transition);
	const resolution = resolveLegacyReminderTransition(
		transition,
		{ reminder: "alarm", reminder_v2: notification, reminder_state_v3: baseState },
		"event-alarm",
	);
	assert.equal(resolution?.state.source, "alarm");
	assert.equal(resolution?.state.base_generation, "client-a:1");
});

test("rapid removal resolves from current legacy value", () => {
	const transition = detectLegacyReminderTransition(
		{ reminder: null, reminder_v2: notification, reminder_state_v3: baseState },
		{ reminder: "alarm", reminder_v2: notification, reminder_state_v3: baseState },
	);
	assert.ok(transition);
	const resolution = resolveLegacyReminderTransition(
		transition,
		{ reminder: null, reminder_v2: notification, reminder_state_v3: baseState },
		"event-create-arrived-late",
	);
	assert.equal(resolution?.state.source, "none");
});

test("duplicate and out-of-order events are idempotent", () => {
	const transition = detectLegacyReminderTransition(
		{ reminder: null, reminder_v2: notification, reminder_state_v3: baseState },
		{ reminder: "alarm", reminder_v2: notification, reminder_state_v3: baseState },
	);
	assert.ok(transition);
	const bridged = {
		version: 3,
		source: "none",
		generation: "legacy:event-remove",
		base_generation: "client-a:1",
		writer: "legacy_bridge",
		event_id: "event-remove",
	};
	assert.equal(
		resolveLegacyReminderTransition(
			transition,
			{ reminder: null, reminder_state_v3: bridged },
			"event-create",
		),
		null,
	);
});

test("a newer v3 generation wins over a delayed legacy event", () => {
	const transition = detectLegacyReminderTransition(
		{ reminder: null, reminder_v2: notification, reminder_state_v3: baseState },
		{ reminder: "alarm", reminder_v2: notification, reminder_state_v3: baseState },
	);
	assert.ok(transition);
	const newerState = {
		version: 3,
		source: "notification",
		generation: "client-b:2",
	};
	assert.equal(
		resolveLegacyReminderTransition(
			transition,
			{
				reminder: null,
				reminder_v2: { version: 2, data: { revision: 2 } },
				reminder_state_v3: newerState,
			},
			"event-old",
		),
		null,
	);
});
