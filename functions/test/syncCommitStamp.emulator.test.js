const assert = require("node:assert/strict");
const test = require("node:test");
const admin = require("firebase-admin");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");

const delay = (milliseconds) =>
	new Promise((resolve) => setTimeout(resolve, milliseconds));

async function waitForNewMarker(reference, previousMarker) {
	const deadline = Date.now() + 20_000;
	while (Date.now() < deadline) {
		const marker = (await reference.get()).get("sync_committed_at");
		if (
			marker instanceof Timestamp &&
			(previousMarker === undefined ||
				marker.seconds !== previousMarker.seconds ||
				marker.nanoseconds !== previousMarker.nanoseconds)
		) {
			return marker;
		}
		await delay(100);
	}
	throw new Error(`Timed out waiting for sync marker on ${reference.path}`);
}

test(
	"legacy note and label writes receive a fresh server commit marker",
	{ timeout: 30_000 },
	async () => {
		assert.ok(
			process.env.FIRESTORE_EMULATOR_HOST,
			"FIRESTORE_EMULATOR_HOST must be provided by emulators:exec",
		);

		const suffix = `${Date.now()}-${process.pid}`;
		const app = admin.initializeApp(
			{ projectId: "better-keep-notes" },
			`sync-commit-stamp-${suffix}`,
		);
		const db = getFirestore(app);
		const user = db.collection("users").doc(`sync-stamp-${suffix}`);
		const note = user.collection("notes").doc("legacy-note");
		const label = user.collection("labels").doc("legacy-label");

		try {
			await Promise.all([
				note.set({
					local_id: 1,
					updated_at: "2026-01-01T00:00:00.000Z",
				}),
				label.set({
					local_id: 1,
					name: "Legacy",
					updated_at: "2026-01-01T00:00:00.000Z",
				}),
			]);

			const [firstNoteMarker, firstLabelMarker] = await Promise.all([
				waitForNewMarker(note),
				waitForNewMarker(label),
			]);

			await Promise.all([
				note.set(
					{ updated_at: "2026-01-02T00:00:00.000Z" },
					{ merge: true },
				),
				label.set({ name: "Legacy updated" }, { merge: true }),
			]);

			const [secondNoteMarker, secondLabelMarker] = await Promise.all([
				waitForNewMarker(note, firstNoteMarker),
				waitForNewMarker(label, firstLabelMarker),
			]);

			assert.notDeepEqual(secondNoteMarker, firstNoteMarker);
			assert.notDeepEqual(secondLabelMarker, firstLabelMarker);
		} finally {
			await Promise.all([
				note.delete().catch(() => {}),
				label.delete().catch(() => {}),
			]);
			await app.delete();
		}
	},
);
