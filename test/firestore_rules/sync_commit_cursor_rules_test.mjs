import { after, before, beforeEach, test } from "node:test";
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  Timestamp,
  doc,
  documentId,
  getDoc,
  getDocs,
  orderBy,
  query,
  serverTimestamp,
  setDoc,
  startAfter,
  updateDoc,
  collection,
} from "firebase/firestore";

const projectId = "demo-better-keep-sync-cursor-rules";
const ownerId = "sync-owner";
const proClaims = {
  plan: "pro",
  planExpiresAt: 4102444800000,
};
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: { rules: await readFile("firestore.rules", "utf8") },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

after(async () => {
  await testEnv.cleanup();
});

function ownerFirestore() {
  return testEnv.authenticatedContext(ownerId, proClaims).firestore();
}

test("an old content timestamp is still discovered by commit cursor", async () => {
  const db = ownerFirestore();
  const notes = collection(db, `users/${ownerId}/notes`);
  const checkpointRef = doc(notes, "checkpoint");

  await assertSucceeds(
    setDoc(checkpointRef, {
      local_id: 1,
      updated_at: "2026-07-29T12:00:00.000Z",
      sync_committed_at: serverTimestamp(),
    }),
  );
  const checkpoint = await getDoc(checkpointRef);
  const checkpointTimestamp = checkpoint.data().sync_committed_at;

  await assertSucceeds(
    setDoc(doc(notes, "delayed"), {
      local_id: 2,
      // This edit happened before the receiving device's old wall-clock
      // cursor, but was uploaded only after the user upgraded to Pro.
      updated_at: "2026-01-01T00:00:00.000Z",
      sync_committed_at: serverTimestamp(),
    }),
  );

  const changes = await getDocs(
    query(
      notes,
      orderBy("sync_committed_at"),
      orderBy(documentId()),
      startAfter(checkpointTimestamp, checkpoint.id),
    ),
  );

  assert.deepEqual(changes.docs.map((snapshot) => snapshot.id), ["delayed"]);
});

test("rules accept server markers and backward-compatible legacy writes", async () => {
  const db = ownerFirestore();
  const notes = collection(db, `users/${ownerId}/notes`);

  await assertSucceeds(
    setDoc(doc(notes, "new-client"), {
      local_id: 1,
      sync_committed_at: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    setDoc(doc(notes, "legacy-client"), {
      local_id: 2,
    }),
  );
  await assertSucceeds(
    updateDoc(doc(notes, "legacy-client"), {
      updated_at: "2026-01-01T00:00:00.000Z",
    }),
  );
  await assertSucceeds(
    updateDoc(doc(notes, "new-client"), {
      updated_at: "2026-01-02T00:00:00.000Z",
    }),
  );
});

test("rules reject client-forged commit positions", async () => {
  const db = ownerFirestore();
  const noteRef = doc(db, `users/${ownerId}/notes/forged`);

  await assertFails(
    setDoc(noteRef, {
      local_id: 1,
      sync_committed_at: Timestamp.fromMillis(1),
    }),
  );

  await assertSucceeds(
    setDoc(noteRef, {
      local_id: 1,
      sync_committed_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(noteRef, {
      sync_committed_at: Timestamp.fromMillis(2),
    }),
  );
});
