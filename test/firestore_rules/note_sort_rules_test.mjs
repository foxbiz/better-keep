import assert from "node:assert/strict";
import { after, before, beforeEach, test } from "node:test";
import { readFile } from "node:fs/promises";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
} from "firebase/firestore";

const projectId = "demo-better-keep-rules";
const ownerId = "owner";
const otherId = "other";
const contextId = "main:grid";
const revision = "revision-1";
const manifestPath = `users/${ownerId}/note_order_contexts/${contextId}`;
const chunkPath =
  `users/${ownerId}/note_order_context_snapshots/${revision}/chunks/000000`;

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: await readFile("firestore.rules", "utf8"),
    },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

after(async () => {
  await testEnv.cleanup();
});

function firestoreFor(uid, { paid = false } = {}) {
  const claims = paid
    ? { plan: "pro", planExpiresAt: 4102444800000 }
    : {};
  return testEnv.authenticatedContext(uid, claims).firestore();
}

function validManifest(overrides = {}) {
  return {
    schema_version: 2,
    context_key: contextId,
    sort_mode: "custom",
    revision,
    chunk_count: 1,
    note_count: 2,
    updated_at: serverTimestamp(),
    ...overrides,
  };
}

function validChunk(overrides = {}) {
  return {
    schema_version: 2,
    revision,
    note_ids: ["note-a", "note-b"],
    ...overrides,
  };
}

async function seed(path, value) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), path),
      value,
    );
  });
}

test("unauthenticated clients cannot read or write ordering data", async () => {
  const db = testEnv.unauthenticatedContext().firestore();

  await assertFails(getDoc(doc(db, manifestPath)));
  await assertFails(setDoc(doc(db, manifestPath), validManifest()));
  await assertFails(getDoc(doc(db, chunkPath)));
  await assertFails(setDoc(doc(db, chunkPath), validChunk()));
});

test("owners can read their data but other users cannot", async () => {
  await seed(manifestPath, {
    ...validManifest(),
    updated_at: new Date(),
  });
  await seed(chunkPath, validChunk());

  await assertSucceeds(getDoc(doc(firestoreFor(ownerId), manifestPath)));
  await assertSucceeds(getDoc(doc(firestoreFor(ownerId), chunkPath)));
  await assertFails(getDoc(doc(firestoreFor(otherId), manifestPath)));
  await assertFails(getDoc(doc(firestoreFor(otherId), chunkPath)));
});

test("paid owners can create valid manifests and chunks", async () => {
  const db = firestoreFor(ownerId, { paid: true });

  await assertSucceeds(setDoc(doc(db, manifestPath), validManifest()));
  await assertSucceeds(setDoc(doc(db, chunkPath), validChunk()));
});

test("paid owners can forward source metadata and legacy normalized revision IDs", async () => {
  const db = firestoreFor(ownerId, { paid: true });
  await assertSucceeds(setDoc(doc(db, manifestPath), validManifest({
    revision: `firebase-${"a".repeat(64)}`,
    updated_at: new Date("2026-01-02T03:04:05Z"),
    content_hash: "b".repeat(64),
    sync_meta: {
      version: 1, kind: "order", entityId: contextId,
      revisionId: `firebase-${"a".repeat(64)}`,
      modifiedAtMicros: 1767323045000000, deleted: false,
      payloadHash: "c".repeat(64),
    },
  })));
});

test("free owners cannot create or update ordering data", async () => {
  const db = firestoreFor(ownerId);
  await assertFails(setDoc(doc(db, manifestPath), validManifest()));
  await assertFails(setDoc(doc(db, chunkPath), validChunk()));

  await seed(manifestPath, {
    ...validManifest(),
    updated_at: new Date(),
  });
  await seed(chunkPath, validChunk());
  await assertFails(
    setDoc(doc(db, manifestPath), validManifest({ sort_mode: "updatedNewest" })),
  );
  await assertFails(
    setDoc(doc(db, chunkPath), validChunk({ note_ids: ["changed"] })),
  );
});

test("ordering tombstones are empty manifests restricted to paid owners", async () => {
  const tombstone = validManifest({
    deleted: true, chunk_count: 0, note_count: 0,
    content_hash: '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945',
  });
  const paid = doc(firestoreFor(ownerId, {paid: true}), manifestPath);
  await assertSucceeds(setDoc(paid, tombstone));
  await assertSucceeds(getDoc(doc(firestoreFor(ownerId), manifestPath)));
  await assertFails(setDoc(doc(firestoreFor(ownerId), manifestPath), tombstone));
  await assertFails(setDoc(doc(firestoreFor(otherId, {paid: true}), manifestPath), tombstone));
  for (const fields of [
    {deleted: 'true'}, {deleted: false}, {chunk_count: 1, note_count: 1},
    {sort_mode: 'updatedNewest'}, {content_hash: 'a'.repeat(64)},
  ]) await assertFails(setDoc(paid, {...tombstone, ...fields}));
});

test("owners can delete existing ordering data after downgrade", async () => {
  await seed(manifestPath, {
    ...validManifest(),
    updated_at: new Date(),
  });
  await seed(chunkPath, validChunk());
  const db = firestoreFor(ownerId);

  await assertSucceeds(deleteDoc(doc(db, manifestPath)));
  await assertSucceeds(deleteDoc(doc(db, chunkPath)));
  await assertSucceeds(
    deleteDoc(
      doc(
        db,
        `users/${ownerId}/note_order_context_snapshots/missing/chunks/000001`,
      ),
    ),
  );
});

test("manifest validation rejects malformed and excessive payloads", async () => {
  const db = firestoreFor(ownerId, { paid: true });
  const invalidPayloads = [
    validManifest({ schema_version: 1 }),
    validManifest({ context_key: "main:list" }),
    validManifest({ sort_mode: "unsupported" }),
    validManifest({ revision: "x".repeat(257) }),
    validManifest({ chunk_count: 501 }),
    validManifest({ note_count: 1000001 }),
    validManifest({ chunk_count: 0, note_count: 1 }),
    validManifest({ chunk_count: 2, note_count: 2000 }),
    validManifest({ updated_at: "not-a-timestamp" }),
    validManifest({ content_hash: "not-a-hash" }),
    validManifest({ sync_meta: "not-a-map" }),
    validManifest({ unexpected: true }),
  ];

  for (const payload of invalidPayloads) {
    await assertFails(setDoc(doc(db, manifestPath), payload));
  }
});

test("chunk validation rejects mismatches, extras, and oversized lists", async () => {
  const db = firestoreFor(ownerId, { paid: true });
  const invalidPayloads = [
    validChunk({ schema_version: 1 }),
    validChunk({ revision: "different-revision" }),
    validChunk({ note_ids: "not-a-list" }),
    validChunk({ note_ids: Array.from({ length: 2001 }, (_, i) => `n-${i}`) }),
    validChunk({ unexpected: true }),
  ];

  for (const payload of invalidPayloads) {
    await assertFails(setDoc(doc(db, chunkPath), payload));
  }
});

test("the generic owner wildcard cannot bypass explicit ordering rules", async () => {
  const freeOwner = firestoreFor(ownerId);
  const paidOther = firestoreFor(otherId, { paid: true });

  await assertFails(setDoc(doc(freeOwner, manifestPath), validManifest()));
  await assertFails(setDoc(doc(freeOwner, chunkPath), validChunk()));
  await assertFails(setDoc(doc(paidOther, manifestPath), validManifest()));
  await assertFails(setDoc(doc(paidOther, chunkPath), validChunk()));
  assert.ok(true);
});
