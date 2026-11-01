import { after, before, beforeEach, test } from 'node:test';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, deleteDoc, onSnapshot, serverTimestamp, Timestamp } from 'firebase/firestore';

let env;
const path = 'users/owner/storage_sync_signals/google_drive';
const connectionPath = 'users/owner/storage_connections/google_drive';
const claims = (plan = 'lite') => ({plan, planExpiresAt: Date.now() + 3600000});
const connection = {enabled: true, state: 'ready', libraryId: 'library', generation: 1, storageEpoch: 'epoch'};
const signal = (extra = {}) => ({libraryId: 'library', generation: 1, storageEpoch: 'epoch', deviceId: 'device-a', token: 'revision-a', updatedAt: serverTimestamp(), ...extra});
before(async () => {
  env = await initializeTestEnvironment({projectId: 'demo-better-keep-signals', firestore: {rules: await readFile('firestore.rules', 'utf8')}});
});
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), connectionPath), connection);
  });
});
after(async () => env?.cleanup());

test('only an unexpired Lite or Pro owner can read and publish hints', async () => {
  for (const plan of ['lite', 'pro']) {
    const ref = doc(env.authenticatedContext('owner', claims(plan)).firestore(), path);
    await assertSucceeds(getDoc(ref));
  }
  await assertSucceeds(setDoc(doc(env.authenticatedContext('owner', claims()).firestore(), path), signal()));
  for (const context of [env.unauthenticatedContext(), env.authenticatedContext('other', claims()), env.authenticatedContext('owner'), env.authenticatedContext('owner', claims('free')), env.authenticatedContext('owner', {...claims(), planExpiresAt: 1}), env.authenticatedContext('owner', {...claims(), appReview: true})]) {
    await assertFails(getDoc(doc(context.firestore(), path)));
    await assertFails(setDoc(doc(context.firestore(), path), signal()));
  }
});

test('rejects stale scope, content, credentials and nested catch-all writes', async () => {
  const db = env.authenticatedContext('owner', claims()).firestore();
  for (const extra of [{libraryId: 'other'}, {generation: 'stale'}, {storageEpoch: 'stale'}, {token: ''}, {token: 'x'.repeat(129)}, {deviceId: '../bad'}, {credentials: 'secret'}, {note: 'plaintext'}, {updatedAt: Timestamp.fromMillis(1)}]) {
    await assertFails(setDoc(doc(db, path), signal(extra)));
  }
  await assertFails(setDoc(doc(db, `${path}/nested/data`), signal()));
  await assertFails(getDoc(doc(db, `${path}/nested/data`)));
  await assertFails(setDoc(doc(db, 'users/owner/storage_sync_signals/unknown'), signal()));
  await assertFails(deleteDoc(doc(db, path)));
});

test('disabled connections cannot publish, and consecutive writes are rate limited', async () => {
  const db = env.authenticatedContext('owner', claims()).firestore();
  await assertSucceeds(setDoc(doc(db, path), signal()));
  await assertFails(setDoc(doc(db, path), signal({token: 'revision-b'})));
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), path), signal({updatedAt: Timestamp.fromMillis(Date.now() - 11000)}));
  });
  await assertSucceeds(setDoc(doc(db, path), signal({token: 'revision-b'})));
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), connectionPath), {...connection, enabled: false});
  });
  await assertFails(setDoc(doc(db, path), signal({token: 'revision-c'})));
});

test('a new valid connection generation can replace its old signal immediately', async () => {
  const db = env.authenticatedContext('owner', claims()).firestore();
  await assertSucceeds(setDoc(doc(db, path), signal()));
  await env.withSecurityRulesDisabled(async context => {
    await setDoc(doc(context.firestore(), connectionPath), {...connection, generation: 2});
  });
  await assertFails(setDoc(doc(db, path), signal({token: 'old'})));
  await assertSucceeds(setDoc(doc(db, path), signal({generation: 2, token: 'new'})));
});

// Separate SDK contexts model two signed-in devices, rather than a local write
// echo. Only committed server snapshots count as notification delivery.
function nextCommittedSnapshot(ref, matches) {
  let unsubscribe;
  let timeout;
  const promise = new Promise((resolve, reject) => {
    timeout = setTimeout(() => {
      unsubscribe?.();
      reject(new Error('Timed out waiting for a committed sync hint'));
    }, 10000);
    unsubscribe = onSnapshot(ref, {includeMetadataChanges: true}, snapshot => {
      if (snapshot.metadata.fromCache || snapshot.metadata.hasPendingWrites || !matches(snapshot)) return;
      clearTimeout(timeout);
      unsubscribe();
      resolve(snapshot);
    }, error => {
      clearTimeout(timeout);
      unsubscribe?.();
      reject(error);
    });
  });
  return {promise, close: () => { clearTimeout(timeout); unsubscribe?.(); }};
}

test('a second device receives a committed hint and a new listener catches up', async () => {
  const writer = env.authenticatedContext('owner', claims()).firestore();
  const reader = env.authenticatedContext('owner', claims()).firestore();
  const readerRef = doc(reader, path);
  const ready = nextCommittedSnapshot(readerRef, snapshot => !snapshot.exists());
  await ready.promise;
  const delivered = nextCommittedSnapshot(readerRef, snapshot => snapshot.data()?.token === 'revision-a');
  try {
    await assertSucceeds(setDoc(doc(writer, path), signal()));
    const snapshot = await delivered.promise;
    assert.equal(snapshot.data().deviceId, 'device-a');
    assert.ok(snapshot.data().updatedAt instanceof Timestamp);
    assert.deepEqual(Object.keys(snapshot.data()).sort(), ['libraryId', 'generation', 'storageEpoch', 'deviceId', 'token', 'updatedAt'].sort());
  } finally {
    delivered.close();
  }

  // A device that was closed during the write gets the latest hint on resume.
  const returningReader = env.authenticatedContext('owner', claims()).firestore();
  const caughtUp = nextCommittedSnapshot(doc(returningReader, path), snapshot => snapshot.data()?.token === 'revision-a');
  try {
    await caughtUp.promise;
  } finally {
    caughtUp.close();
  }
});
