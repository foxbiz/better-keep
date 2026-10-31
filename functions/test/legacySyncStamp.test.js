const assert = require('node:assert/strict');
const test = require('node:test');
const { Timestamp } = require('firebase-admin/firestore');
const { stampLegacySyncDocument } = require('../lib/legacySyncStamp');

function fixture(data) {
  const writes = [];
  const paths = [];
  const updateTime = Timestamp.fromMillis(1000);
  const database = {
    doc(path) { paths.push(path); return path; },
    async runTransaction(action) {
      await action({
        get: async () => ({ data: () => data, updateTime }),
        update: (ref, patch) => writes.push([ref, patch]),
      });
    },
  };
  return { database, writes, paths, updateTime };
}

for (const [kind, collection] of Object.entries({ note: 'notes', label: 'labels', order: 'note_order_contexts' })) {
  test(`legacy ${kind} uses the owner's original database update time`, async () => {
    const f = fixture({ updated_at: '2026-10-24T12:00:00', title: 'preserved' });
    await stampLegacySyncDocument(f.database, 'owner', { kind, entityId: 'id', uid: 'other' });
    assert.deepEqual(f.paths, [`users/owner/${collection}/id`]);
    assert.deepEqual(f.writes, [[f.paths[0], { sync_committed_at: f.updateTime }]]);
  });
}

test('valid explicit dates and server stamps are left intact', async () => {
  for (const data of [
    { updated_at: '2026-10-24T12:00:00Z' },
    { updated_at: '2026-10-24T12:00:00+05:30' },
    { updated_at: Timestamp.fromMillis(100) },
    { updated_at: '2026-10-24T12:00:00', sync_committed_at: Timestamp.fromMillis(100) },
  ]) {
    const f = fixture(data);
    await stampLegacySyncDocument(f.database, 'owner', { kind: 'note', entityId: 'id' });
    assert.equal(f.writes.length, 0);
  }
});

test('missing auth, invalid kind/path and deleted documents cannot be stamped', async () => {
  const f = fixture(undefined);
  await assert.rejects(stampLegacySyncDocument(f.database, undefined, { kind: 'note', entityId: 'id' }), { code: 'unauthenticated' });
  for (const input of [
    undefined,
    { kind: '__proto__', entityId: 'id' },
    ...['../id', '.', '..', ...Array.from({ length: 32 }, (_, code) => `id${String.fromCharCode(code)}`)]
      .map(entityId => ({ kind: 'note', entityId })),
  ]) {
    await assert.rejects(stampLegacySyncDocument(f.database, 'owner', input), { code: 'invalid-argument' });
  }
  assert.equal(f.paths.length, 0);
  await assert.rejects(stampLegacySyncDocument(f.database, 'owner', { kind: 'note', entityId: 'id' }), { code: 'not-found' });
  assert.equal(f.writes.length, 0);
});
