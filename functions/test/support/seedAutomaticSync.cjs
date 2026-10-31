// Disposable emulator fixture for the Flutter automatic-sync acceptance test.
const assert = require('node:assert/strict');
const { createHash, hkdfSync } = require('node:crypto');
assert.equal(process.env.GCLOUD_PROJECT, 'demo-better-keep-signals');
assert.ok(process.env.FIRESTORE_EMULATOR_HOST?.startsWith('127.0.0.1:'));
assert.ok(process.env.FIREBASE_AUTH_EMULATOR_HOST?.startsWith('127.0.0.1:'));
process.env.FUNCTIONS_EMULATOR = 'true';
const { app, auth, db } = require('../../lib/config');

(async () => {
  const uid = 'automatic-sync-qa';
  const identity = Buffer.from(hkdfSync('sha256', Buffer.alloc(32), uid, 'better-keep/external-sync/v1/library', 32));
  const libraryId = createHash('sha256').update(identity).digest('hex');
  await auth.createUser({uid, email: 'automatic-sync-qa@example.test',
    password: 'Disposable-QA-Only-123!', emailVerified: true});
  await auth.setCustomUserClaims(uid, {plan: 'lite', planExpiresAt: Date.now() + 3600000});
  await db.doc(`users/${uid}/storage_connections/dropbox`).set({
    enabled: true, state: 'ready', generation: 1, storageEpoch: '', libraryId,
  });
  await db.terminate();
  await app.delete();
  console.log('Disposable automatic-sync fixture ready');
})().catch(error => { console.error(error); process.exitCode = 1; });
