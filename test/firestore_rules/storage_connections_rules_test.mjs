import { after, before, beforeEach, test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, updateDoc, deleteDoc, serverTimestamp } from 'firebase/firestore';

let env;
before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-better-keep-storage-connections',
    firestore: { rules: await readFile('firestore.rules', 'utf8') } });
});
beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'users/owner/storage_credentials/google_drive'), { credentials: 'encrypted', capabilityHash: 'private' });
    await setDoc(doc(context.firestore(), 'users/owner/storage_connections/google_drive'), { enabled: true, encryptedCapability: 'encrypted-for-umk' });
  });
});
after(async () => env?.cleanup());

test('even the authenticated owner cannot read or modify the credential vault', async () => {
  for (const context of [env.authenticatedContext('owner'), env.authenticatedContext('other'), env.unauthenticatedContext()]) {
    const ref = doc(context.firestore(), 'users/owner/storage_credentials/google_drive');
    await assertFails(getDoc(ref));
    await assertFails(setDoc(ref, { capabilityHash: 'attacker-controlled' }));
    await assertFails(updateDoc(ref, { credentials: 'replacement' }));
    await assertFails(updateDoc(ref, { refreshBinding: 'a'.repeat(64), 'lease.exchange.nextBinding': 'b'.repeat(64) }));
    await assertFails(deleteDoc(ref));
  }
});

test('metadata can be read by its owner but only the backend can change it', async () => {
  const owner = env.authenticatedContext('owner').firestore();
  const ref = doc(owner, 'users/owner/storage_connections/google_drive');
  await assertSucceeds(getDoc(ref));
  await assertFails(setDoc(ref, { encryptedCapability: 'replacement' }));
  await assertFails(updateDoc(ref, { enabled: false }));
  await assertFails(deleteDoc(ref));
  await assertFails(getDoc(doc(env.authenticatedContext('other').firestore(), ref.path)));
  await assertFails(getDoc(doc(env.authenticatedContext('owner', { appReview: true }).firestore(), ref.path)));
});

test('owner catch-all cannot bypass restrictions using nested documents', async () => {
  const owner = env.authenticatedContext('owner').firestore();
  for (const collection of ['storage_credentials', 'storage_connections']) {
    await assertFails(setDoc(doc(owner, `users/owner/${collection}/google_drive/nested/secret`), { value: 'injected' }));
  }
});

 test('OAuth sessions are never exposed to clients', async () => {
  for (const context of [env.authenticatedContext('owner'), env.unauthenticatedContext()]) {
    const ref = doc(context.firestore(), 'storageOAuthSessions/session');
    await assertFails(getDoc(ref));
    await assertFails(setDoc(ref, {state: 'authorized'}));
  }
});


test('Firebase sync selection is owner-controlled without a Pro entitlement', async () => {
  const owner = env.authenticatedContext('owner').firestore();
  const path = 'users/owner/sync_settings/firebase';
  const ref = doc(owner, path);
  await assertSucceeds(getDoc(ref));
  await assertSucceeds(setDoc(ref, {enabled: false, updatedAt: serverTimestamp()}));
  await assertSucceeds(updateDoc(ref, {enabled: true, updatedAt: serverTimestamp()}));
  await assertFails(setDoc(ref, {enabled: 'yes', updatedAt: serverTimestamp()}));
  await assertFails(setDoc(ref, {enabled: false}));
  await assertFails(setDoc(ref, {enabled: false, updatedAt: serverTimestamp(), injected: true}));
  await assertFails(deleteDoc(ref));
  for (const ctx of [env.authenticatedContext('other'), env.unauthenticatedContext(), env.authenticatedContext('owner', {appReview: true})]) {
    await assertFails(getDoc(doc(ctx.firestore(), path)));
    await assertFails(setDoc(doc(ctx.firestore(), path), {enabled: false, updatedAt: serverTimestamp()}));
  }
  await assertFails(setDoc(doc(owner, 'users/owner/sync_settings/other'), {enabled: false, updatedAt: serverTimestamp()}));
  await assertFails(setDoc(doc(owner, `${path}/nested/secret`), {enabled: false}));
});


test('selection accepts exactly one known provider consistent with the Firebase flag', async () => {
  const ref = doc(env.authenticatedContext('owner').firestore(), 'users/owner/sync_settings/firebase');
  for (const provider of ['firebase', 'google_drive', 'dropbox', 'nextcloud', 'none']) {
    await assertSucceeds(setDoc(ref, {provider, enabled: provider === 'firebase', updatedAt: serverTimestamp()}));
    await assertFails(setDoc(ref, {provider, enabled: provider !== 'firebase', updatedAt: serverTimestamp()}));
  }
  for (const provider of ['other', ['google_drive', 'dropbox'], null]) {
    await assertFails(setDoc(ref, {provider, enabled: false, updatedAt: serverTimestamp()}));
  }
});
