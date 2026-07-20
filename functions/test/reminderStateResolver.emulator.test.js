const assert = require("node:assert/strict");
const test = require("node:test");
const admin = require("firebase-admin");
const { getFirestore } = require("firebase-admin/firestore");

const delay = (milliseconds) =>
	new Promise((resolve) => setTimeout(resolve, milliseconds));

test(
	"legacy alarm creation and removal cannot expose stale reminder_v2",
	{ timeout: 30_000 },
	async () => {
		assert.ok(
			process.env.FIRESTORE_EMULATOR_HOST,
			"FIRESTORE_EMULATOR_HOST must be provided by emulators:exec",
		);
		const app = admin.initializeApp(
			{ projectId: "better-keep-notes" },
			`reminder-resolver-${Date.now()}`,
		);
		const db = getFirestore(app);
		const ref = db
			.collection("users")
			.doc("reminder-resolver-test")
			.collection("notes")
			.doc(`note-${Date.now()}`);
		const notification = {
			version: 2,
			data: {
				type: "notification",
				dateTime: "2026-07-20T10:00:00.000",
				revision: 1,
			},
		};
		const source = {
			version: 3,
			source: "notification",
			generation: "client:1:notification",
		};
		const updatedAt = "2026-07-20T10:00:00.000";

		try {
			await ref.set({
				local_id: 42,
				updated_at: updatedAt,
				reminder: null,
				reminder_v2: notification,
				reminder_state_v3: source,
			});
			await ref.set({ reminder: "legacy-alarm" }, { merge: true });
			await ref.set({ reminder: null }, { merge: true });

			let resolved;
			const deadline = Date.now() + 20_000;
			while (Date.now() < deadline) {
				resolved = (await ref.get()).data();
				if (
					resolved &&
					!("reminder_v2" in resolved) &&
					resolved.reminder_state_v3?.source === "none"
				) {
					break;
				}
				await delay(100);
			}

			assert.ok(resolved);
			assert.equal("reminder_v2" in resolved, false);
			assert.equal(resolved.reminder_state_v3.source, "none");
			assert.equal(resolved.updated_at, updatedAt);
		} finally {
			await ref.delete().catch(() => {});
			await app.delete();
		}
	},
);
