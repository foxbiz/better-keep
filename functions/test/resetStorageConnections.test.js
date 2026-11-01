const assert = require('node:assert/strict');
const test = require('node:test');
const { resetStorageConnections } = require('../lib/resetStorageConnections');

test('verified reset retires only key-bound grants and provider selection', async () => {
  const deleted = [];
  let commits = 0;
  const db = { batch: () => ({
    delete: (ref) => deleted.push(ref),
    commit: async () => { commits++; },
  }) };
  const user = { collection: (name) => ({ doc: (id) => `${name}/${id}` }) };
  await resetStorageConnections(db, user);
  assert.equal(commits, 1);
  assert.deepEqual(deleted, [
    'storage_credentials/google_drive', 'storage_connections/google_drive',
    'storage_credentials/dropbox', 'storage_connections/dropbox',
    'storage_credentials/nextcloud', 'storage_connections/nextcloud',
    'storage_credentials/webdav', 'storage_connections/webdav',
    'sync_settings/firebase',
  ]);
});
